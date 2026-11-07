import Foundation
import OSLog

/// One opened video: resolves streams, owns the mpv player, and applies preferences.
@Observable
final class PlayerSession: Identifiable {
    enum Phase: Equatable {
        case resolving, ready, failed(String)
    }

    let id = UUID()
    let video: Video
    let player: MPVPlayer
    private(set) var phase: Phase = .resolving
    private(set) var info: StreamInfo?
    private(set) var selection: StreamInfo.Selection?
    /// The quality the user picked for this video (defaults to the preference).
    private(set) var quality: VideoQuality

    @ObservationIgnored private let resolver: StreamResolver
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "Player")

    init(video: Video, resolver: StreamResolver, preferences: Preferences) {
        self.video = video
        self.resolver = resolver
        self.prefs = preferences
        self.quality = preferences.quality
        self.player = MPVPlayer(options: .init(
            hardwareDecoding: preferences.hardwareDecoding,
            bufferMB: preferences.bufferMB,
            speed: preferences.defaultSpeed
        ))
    }

    func start() {
        loadTask?.cancel()
        phase = .resolving
        loadTask = Task {
            let start = ContinuousClock.now
            do {
                let info = try await resolver.resolve(video.id, isLive: video.kind == .live)
                try Task.checkCancellation()
                self.info = info
                log.info("Streams ready for \(self.video.id, privacy: .public) after \(ContinuousClock.now - start, privacy: .public)")
                play(info, at: 0, autoplay: prefs.autoplay)
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
                player.fail(error.localizedDescription)
            }
        }
    }

    /// Switches quality, keeping the playback position.
    func setQuality(_ q: VideoQuality) {
        guard q != quality, let info else { quality = q; return }
        quality = q
        play(info, at: player.position, autoplay: !player.isPaused)
    }

    /// Qualities this video actually offers.
    var availableQualities: [VideoQuality] {
        let heights = Set(info?.formats.filter(\.hasVideo).compactMap(\.height) ?? [])
        return VideoQuality.allCases.filter { q in q == .auto || heights.contains(q.rawValue) }
    }

    func retry() {
        Task { await resolver.invalidate(video.id) }
        start()
    }

    func close() {
        loadTask?.cancel()
        player.stop()
    }

    private func play(_ info: StreamInfo, at time: Double, autoplay: Bool) {
        guard let selection = info.select(quality: quality, codec: prefs.codec) else {
            phase = .failed("No playable stream was found for this video.")
            return
        }
        self.selection = selection
        log.info("Playing \(selection.video.id, privacy: .public) \(selection.video.height ?? 0)p \(selection.video.vcodec ?? "", privacy: .public) + \(selection.audio?.id ?? "muxed", privacy: .public)")
        player.load(selection, startAt: time, autoplay: autoplay)
        phase = .ready
    }
}
