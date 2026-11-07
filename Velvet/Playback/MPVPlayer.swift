import Foundation
import AppKit
import QuartzCore
import Libmpv
import OSLog

/// CAMetalLayer with MPVKit's MoltenVK flicker workaround (see mpv-player/mpv#13651).
nonisolated final class MPVMetalLayer: CAMetalLayer, @unchecked Sendable {
    /// MoltenVK briefly sets a 1×1 drawable to force presentation, which flickers; ignore it.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }
}

/// Owns the mpv handle and its event loop. All mpv calls happen on `queue` or are thread-safe C API calls.
private nonisolated final class MPVCore: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    let queue = DispatchQueue(label: "com.subhash.Velvet.mpv", qos: .userInitiated)
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "mpv")
    /// Called on `queue` with (property name, value).
    var onProperty: ((String, PropertyValue) -> Void)?
    var onEvent: ((mpv_event_id) -> Void)?

    enum PropertyValue: Sendable {
        case flag(Bool), double(Double), string(String), none
    }

    init?(layer: CAMetalLayer, options: [(String, String)]) {
        guard let mpv = mpv_create() else { return nil }
        handle = mpv

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
        for (k, v) in options { check(mpv_set_option_string(mpv, k, v), "option \(k)=\(v)") }
        #if DEBUG
        mpv_request_log_messages(mpv, "warn")
        #endif

        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            handle = nil
            return nil
        }

        // Unretained is safe: shutdown() clears the callback before the core can be freed.
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let core = Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue()
            core.queue.async { core.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func observe(_ name: String, _ format: mpv_format) {
        guard let handle else { return }
        mpv_observe_property(handle, 0, name, format)
    }

    func command(_ args: [String]) {
        queue.async { [self] in
            guard let handle else { return }
            var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
            defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p!)) } }
            check(mpv_command(handle, &cargs), "command \(args.first ?? "")")
        }
    }

    func set(_ name: String, _ value: String) {
        queue.async { [self] in
            guard let handle else { return }
            check(mpv_set_property_string(handle, name, value), "set \(name)")
        }
    }

    func setFlag(_ name: String, _ value: Bool) {
        queue.async { [self] in
            guard let handle else { return }
            var flag: Int32 = value ? 1 : 0
            check(mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag), "set \(name)")
        }
    }

    func setDouble(_ name: String, _ value: Double) {
        queue.async { [self] in
            guard let handle else { return }
            var v = value
            check(mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v), "set \(name)")
        }
    }

    /// Stops callbacks and destroys mpv. Blocks until the event queue is idle.
    func shutdown() {
        queue.sync {
            guard let handle else { return }
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
    }

    private func drainEvents() {
        while let handle, let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let prop = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else { continue }
                let name = String(cString: prop.name)
                let value: PropertyValue
                switch prop.format {
                case MPV_FORMAT_FLAG: value = .flag(prop.data.assumingMemoryBound(to: Int32.self).pointee != 0)
                case MPV_FORMAT_DOUBLE: value = .double(prop.data.assumingMemoryBound(to: Double.self).pointee)
                case MPV_FORMAT_STRING:
                    value = .string(String(cString: prop.data.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee))
                default: value = .none
                }
                onProperty?(name, value)
            case MPV_EVENT_LOG_MESSAGE:
                if let msg = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                    log.debug("[\(String(cString: msg.prefix), privacy: .public)] \(String(cString: msg.text).trimmingCharacters(in: .newlines), privacy: .public)")
                }
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                if event.error < 0 {
                    log.error("mpv event \(String(cString: mpv_event_name(event.event_id)), privacy: .public): \(String(cString: mpv_error_string(event.error)), privacy: .public)")
                }
                onEvent?(event.event_id)
            }
        }
    }

    private func check(_ status: Int32, _ what: @autoclosure () -> String) {
        guard status < 0 else { return }
        let action = what(), reason = String(cString: mpv_error_string(status))
        log.error("mpv \(action, privacy: .public) failed: \(reason, privacy: .public)")
    }
}

/// Observable playback state + controls for one video surface.
@Observable
final class MPVPlayer {
    let layer = MPVMetalLayer()

    private(set) var isPaused = true
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var bufferedUntil: Double = 0
    private(set) var isBuffering = false
    private(set) var isLoading = false
    private(set) var hasEnded = false
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var speed: Double = 1
    private(set) var videoSize: CGSize?
    private(set) var failure: String?

    /// Fired (on the main actor) as playback time advances; used by SponsorBlock.
    @ObservationIgnored var onTimeChange: ((Double) -> Void)?

    @ObservationIgnored private let core: MPVCore?
    @ObservationIgnored private var lastPublishedPosition: Double = -1

    struct Options {
        var hardwareDecoding = true
        var bufferMB = 150
        var speed = 1.0
    }

    init(options: Options) {
        layer.backgroundColor = NSColor.black.cgColor
        layer.framebufferOnly = true
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        core = MPVCore(layer: layer, options: [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", options.hardwareDecoding ? "videotoolbox" : "no"),
            ("ytdl", "no"),
            ("idle", "yes"),
            ("keep-open", "yes"),
            ("osc", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("input-media-keys", "no"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "\(options.bufferMB)MiB"),
            ("demuxer-max-back-bytes", "50MiB"),
            ("network-timeout", "15"),
            // YouTube throttles open-ended range requests to ~500 KB/s; 10 MB chunks get full speed.
            ("stream-lavf-o", "request_size=10485760"),
            ("speed", String(options.speed)),
            ("volume", "100"),
            ("volume-max", "150"),
        ])
        guard let core else {
            failure = "Couldn't start the video engine."
            return
        }
        speed = options.speed

        for (name, format) in [
            ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG),
            ("mute", MPV_FORMAT_FLAG), ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("demuxer-cache-time", MPV_FORMAT_DOUBLE), ("volume", MPV_FORMAT_DOUBLE), ("speed", MPV_FORMAT_DOUBLE),
            ("video-params/w", MPV_FORMAT_DOUBLE), ("video-params/h", MPV_FORMAT_DOUBLE),
        ] as [(String, mpv_format)] {
            core.observe(name, format)
        }

        core.onProperty = { [weak self] name, value in
            Task { @MainActor in self?.apply(name, value) }
        }
        core.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    deinit {
        core?.shutdown()
    }

    // MARK: - Loading

    /// Plays a resolved selection; separate audio is attached as an external track.
    func load(_ selection: StreamInfo.Selection, startAt: Double = 0, autoplay: Bool = true) {
        guard let core else { return }
        failure = nil
        hasEnded = false
        isLoading = true
        position = startAt
        lastPublishedPosition = -1

        if let ua = selection.video.httpHeaders["User-Agent"] { core.set("user-agent", ua) }
        let extra = selection.video.httpHeaders
            .filter { $0.key != "User-Agent" }
            .map { "\($0.key): \($0.value)" }
        core.set("http-header-fields", extra.map(Self.escapeListItem).joined(separator: ","))

        var fileOptions: [String] = []
        if let audio = selection.audio {
            fileOptions.append("audio-file=\(Self.quoted(audio.url.absoluteString))")
        }
        if startAt > 1 { fileOptions.append("start=\(Int(startAt))") }
        core.setFlag("pause", !autoplay)
        // loadfile <url> <flags> <index> <options>
        core.command(["loadfile", selection.video.url.absoluteString, "replace", "-1", fileOptions.joined(separator: ",")])
    }

    /// mpv's `%length%value` quoting, safe for URLs containing commas or '='.
    private static func quoted(_ value: String) -> String { "%\(value.utf8.count)%\(value)" }

    private static func escapeListItem(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
    }

    // MARK: - Controls

    func play() { if hasEnded { seek(to: 0) }; core?.setFlag("pause", false) }
    func pause() { core?.setFlag("pause", true) }
    func togglePause() { isPaused ? play() : pause() }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        position = target
        hasEnded = false
        core?.command(["seek", String(target), "absolute+exact"])
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func setVolume(_ value: Double) {
        core?.setDouble("volume", max(0, min(150, value)))
        if isMuted && value > 0 { core?.setFlag("mute", false) }
    }

    func toggleMute() { core?.setFlag("mute", !isMuted) }

    func setSpeed(_ value: Double) { core?.setDouble("speed", max(0.25, min(4, value))) }

    func stop() { core?.command(["stop"]) }

    // MARK: - State updates

    private func apply(_ name: String, _ value: MPVCore.PropertyValue) {
        switch (name, value) {
        case ("pause", .flag(let v)): isPaused = v
        case ("paused-for-cache", .flag(let v)): isBuffering = v
        case ("eof-reached", .flag(let v)): hasEnded = v
        case ("mute", .flag(let v)): isMuted = v
        case ("volume", .double(let v)): volume = v
        case ("speed", .double(let v)): speed = v
        case ("duration", .double(let v)): duration = v
        case ("demuxer-cache-time", .double(let v)): bufferedUntil = v
        case ("time-pos", .double(let v)):
            onTimeChange?(v)
            // mpv reports every frame; publishing ~4×/s keeps SwiftUI work negligible.
            if abs(v - lastPublishedPosition) >= 0.25 || v < lastPublishedPosition {
                lastPublishedPosition = v
                position = v
            }
            if isLoading { isLoading = false }
        case ("video-params/w", .double(let w)): videoSize = CGSize(width: w, height: videoSize?.height ?? 0)
        case ("video-params/h", .double(let h)): videoSize = CGSize(width: videoSize?.width ?? 0, height: h)
        default: break
        }
    }

    private func handle(_ event: mpv_event_id) {
        switch event {
        case MPV_EVENT_FILE_LOADED:
            isLoading = false
        case MPV_EVENT_END_FILE:
            isLoading = false
        default:
            break
        }
    }

    /// Records a load failure reported elsewhere (e.g. stream resolution).
    func fail(_ message: String) {
        isLoading = false
        failure = message
    }
}
