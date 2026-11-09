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
    /// Called on `queue` when a file stops; `failed` means mpv couldn't open or play it.
    var onEndFile: ((_ failed: Bool, _ message: String?) -> Void)?

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

    /// The current video frame as an image (mpv `screenshot-raw video`), or nil.
    func snapshot() -> CGImage? {
        queue.sync { () -> CGImage? in
            guard let handle else { return nil }
            let words: [String] = ["screenshot-raw", "video"]
            var cargs: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) } + [nil]
            defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p!)) } }
            var result = mpv_node()
            guard mpv_command_ret(handle, &cargs, &result) >= 0 else { return nil }
            defer { mpv_free_node_contents(&result) }
            guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list?.pointee else { return nil }

            var w = 0, h = 0, stride = 0
            var bytes: Data?
            for i in 0..<Int(list.num) {
                guard let key = list.keys?[i] else { continue }
                let value = list.values[i]
                switch String(cString: key) {
                case "w": w = Int(value.u.int64)
                case "h": h = Int(value.u.int64)
                case "stride": stride = Int(value.u.int64)
                case "data":
                    if value.format == MPV_FORMAT_BYTE_ARRAY, let ba = value.u.ba?.pointee, let ptr = ba.data {
                        bytes = Data(bytes: ptr, count: Int(ba.size))
                    }
                default: break
                }
            }
            // "bgr0": 8-bit B,G,R,unused — little-endian 32-bit with the alpha byte skipped.
            guard w > 0, h > 0, stride > 0, let bytes, let provider = CGDataProvider(data: bytes as CFData) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
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
            case MPV_EVENT_END_FILE:
                if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    let failed = end.reason == MPV_END_FILE_REASON_ERROR
                    onEndFile?(failed, failed ? String(cString: mpv_error_string(end.error)) : nil)
                }
                onEvent?(event.event_id)
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
    /// Plays the video again from the start when it ends (so the queue doesn't advance).
    private(set) var isLooping = false
    private(set) var videoSize: CGSize?
    private(set) var failure: String?
    /// mpv's active hardware decoder ("videotoolbox"), or "no"/empty for software decoding.
    private(set) var hardwareDecoder: String?

    /// Fired (on the main actor) as playback time advances; used by SponsorBlock.
    @ObservationIgnored var onTimeChange: ((Double) -> Void)?
    /// Fired when playback pauses or resumes.
    @ObservationIgnored var onPauseChange: ((Bool) -> Void)?
    /// Fired when a load fails before any frame played (e.g. HTTP 403), so the owner can retry.
    @ObservationIgnored var onLoadFailure: ((String) -> Void)?
    /// Fired once when playback reaches the end (keep-open holds the last frame).
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored private var playedSinceLoad = false

    @ObservationIgnored private let core: MPVCore?
    @ObservationIgnored private var lastPublishedPosition: Double = -1

    struct Options {
        var hardwareDecoding = true
        var bufferMB = 150
        var speed = 1.0
        /// Shorts loop forever, like YouTube's.
        var loop = false
        /// Seconds; positive plays the audio later (Bluetooth latency).
        var audioDelay = 0.0
    }

    init(options: Options) {
        isLooping = options.loop
        layer.backgroundColor = NSColor.black.cgColor
        layer.framebufferOnly = true
        // mpv renders at the video's own resolution; Core Animation scales the frames to whatever
        // size the host view is (page, fullscreen, PiP). Resizing therefore never needs mpv to
        // reconfigure, so animations stay smooth and paused frames stay correct.
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.drawableSize = Self.renderSize(for: CGSize(width: 1920, height: 1080))

        core = MPVCore(layer: layer, options: [
            // Cheap scalers/no extra passes: we render 1:1 at the video's resolution and the
            // final fit is a GPU transform, so mpv's high-quality scaling work would be wasted.
            ("profile", "fast"),
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", options.hardwareDecoding ? "videotoolbox" : "no"),
            ("ytdl", "no"),
            ("idle", "yes"),
            ("keep-open", "yes"),
            ("osc", "no"),
            // mpv's built-in Lua UI scripts (each a thread + Lua VM); Velvet draws its own UI.
            ("load-scripts", "no"),
            ("load-stats-overlay", "no"),
            ("load-console", "no"),
            ("load-select", "no"),
            ("load-positioning", "no"),
            ("load-commands", "no"),
            ("load-context-menu", "no"),
            ("load-auto-profiles", "no"),
            // Fewer spare decoded frames held by the hardware decoder (default 6).
            ("hwdec-extra-frames", "2"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("input-media-keys", "no"),
            ("cache", "yes"),
            // Buffer by time (30s ahead is plenty to ride out hiccups); the MB setting is only a
            // ceiling. mpv's default prefetches up to an hour, i.e. always filling the cap.
            ("cache-secs", "30"),
            ("demuxer-max-bytes", "\(options.bufferMB)MiB"),
            ("demuxer-max-back-bytes", "20MiB"),
            ("network-timeout", "15"),
            // YouTube throttles open-ended range requests to ~500 KB/s; 10 MB chunks get full speed.
            ("stream-lavf-o", "request_size=10485760"),
            ("speed", String(options.speed)),
            ("loop-file", options.loop ? "inf" : "no"),
            ("audio-delay", String(options.audioDelay)),
            ("volume", "100"),
            ("volume-max", "150"),
            // Captions: YouTube-like translucent box, clear of the controls.
            ("sub-font", "SF Pro Display"),
            ("sub-font-size", "40"),
            ("sub-border-style", "background-box"),
            ("sub-back-color", "#B3000000"),
            ("sub-color", "#FFFFFFFF"),
            ("sub-margin-y", "48"),
            ("sub-auto", "no"),
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
            ("hwdec-current", MPV_FORMAT_STRING), ("video-codec", MPV_FORMAT_STRING),
        ] as [(String, mpv_format)] {
            core.observe(name, format)
        }

        core.onProperty = { [weak self] name, value in
            Task { @MainActor in self?.apply(name, value) }
        }
        core.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        core.onEndFile = { [weak self] failed, message in
            guard failed else { return }
            Task { @MainActor in
                guard let self, !self.playedSinceLoad else { return }
                self.onLoadFailure?(message ?? "Couldn't open the stream.")
            }
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
        playedSinceLoad = false
        core.set("video-aspect-override", "no")
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

    // MARK: - Hosting (inline vs Picture in Picture)

    /// True while the video is shown in the Picture in Picture window.
    private(set) var isInPictureInPicture = false
    @ObservationIgnored private weak var inlineSurface: MPVSurfaceView?
    @ObservationIgnored private weak var layerHost: MPVSurfaceView?
    /// Keeps the PiP window's play/pause button in sync.
    @ObservationIgnored var onPictureInPicturePauseChange: ((Bool) -> Void)?

    /// The page's player view. It takes the layer unless PiP currently has it.
    func registerInlineSurface(_ view: MPVSurfaceView) {
        inlineSurface = view
        if !isInPictureInPicture { host(in: view) }
    }

    var inlineView: MPVSurfaceView? { inlineSurface }

    func host(in view: MPVSurfaceView) {
        guard layerHost !== view else { return }
        layerHost?.release()
        view.adopt(layer)
        layerHost = view
    }

    /// Moves the layer into a fresh view for the PiP window. The page's player keeps a still of
    /// the current frame, so the window doesn't show a black hole while it slides away (Spaces).
    func makePictureInPictureView() -> MPVSurfaceView {
        let view = MPVSurfaceView()
        isInPictureInPicture = true
        host(in: view)
        return view
    }

    /// Leaves a still of the current frame on the page while the video is in PiP. Grabbing
    /// it takes mpv a few hundred ms, so it runs after the PiP window is already up.
    func leaveStillOnPage() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isInPictureInPicture else { return }
            self.inlineSurface?.showStill(self.core?.snapshot())
        }
    }

    /// PiP ended: give the layer back to the page's player view.
    func returnFromPictureInPicture() {
        isInPictureInPicture = false
        if let inlineSurface { host(in: inlineSurface) }
    }

    // MARK: - Render size

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var aspectNudge = false

    /// Video size capped to the largest screen (pixels), keeping its aspect ratio.
    nonisolated static func renderSize(for video: CGSize) -> CGSize {
        let screens = NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor,
                                                     height: $0.frame.height * $0.backingScaleFactor) }
        let screen = screens.max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 2880, height: 1800)
        let scale = min(1, screen.width / video.width, screen.height / video.height)
        return CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
    }

    /// When a new video's dimensions arrive, match the drawable to them. MPVKit's MoltenVK
    /// context only reads the drawable size when mpv reconfigures, so nudge
    /// `video-aspect-override` by ~0.001% to trigger that — once per video, not per resize.
    private func videoDimensionsChanged() {
        renderTask?.cancel()
        renderTask = Task {
            // w and h arrive as separate events; settle before acting.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let size = videoSize, size.width > 0, size.height > 0 else { return }
            let target = Self.renderSize(for: size)
            guard target != layer.drawableSize else { return }
            layer.drawableSize = target
            layerHost?.syncDrawable() // re-fit the new drawable into the current view
            aspectNudge.toggle()
            let aspect = size.width / size.height * (aspectNudge ? 1.00001 : 0.99999)
            core?.set("video-aspect-override", String(format: "%.8f", aspect))
        }
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

    func setLooping(_ on: Bool) {
        isLooping = on
        core?.set("loop-file", on ? "inf" : "no")
    }

    func setAudioDelay(milliseconds: Int) { core?.setDouble("audio-delay", Double(milliseconds) / 1000) }

    func stop() { core?.command(["stop"]) }

    /// Shows a local caption file (replacing any current one).
    func showCaptions(file: URL, title: String, language: String) {
        core?.command(["sub-remove"])
        core?.command(["sub-add", file.path, "select", title, language])
    }

    func hideCaptions() {
        core?.command(["sub-remove"])
        core?.set("sid", "no")
    }

    // MARK: - State updates

    private func apply(_ name: String, _ value: MPVCore.PropertyValue) {
        switch (name, value) {
        case ("pause", .flag(let v)):
            if v != isPaused { isPaused = v; onPauseChange?(v); onPictureInPicturePauseChange?(v) }
        case ("paused-for-cache", .flag(let v)): isBuffering = v
        case ("eof-reached", .flag(let v)):
            if v && !hasEnded { onEnded?() }
            hasEnded = v
        case ("mute", .flag(let v)): isMuted = v
        case ("volume", .double(let v)): volume = v
        case ("speed", .double(let v)): speed = v
        case ("duration", .double(let v)): duration = v
        case ("demuxer-cache-time", .double(let v)): bufferedUntil = v
        case ("time-pos", .double(let v)):
            playedSinceLoad = true
            onTimeChange?(v)
            // mpv reports every frame; publishing ~4×/s keeps SwiftUI work negligible.
            if abs(v - lastPublishedPosition) >= 0.25 || v < lastPublishedPosition {
                lastPublishedPosition = v
                position = v
            }
            if isLoading { isLoading = false }
        case ("video-params/w", .double(let w)):
            videoSize = CGSize(width: w, height: videoSize?.height ?? 0)
            videoDimensionsChanged()
        case ("video-params/h", .double(let h)):
            videoSize = CGSize(width: videoSize?.width ?? 0, height: h)
            videoDimensionsChanged()
        case ("hwdec-current", .string(let v)):
            hardwareDecoder = v
            Logger(subsystem: "com.subhash.Velvet", category: "Player").info("Decoder: \(v.isEmpty || v == "no" ? "software" : v, privacy: .public)")
        case ("video-codec", .string(let v)):
            Logger(subsystem: "com.subhash.Velvet", category: "Player").info("Video codec: \(v, privacy: .public)")
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
