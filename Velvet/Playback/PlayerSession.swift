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
    let sponsor: SponsorSkipper
    let page: WatchPageModel
    private(set) var phase: Phase = .resolving
    private(set) var info: StreamInfo?
    private(set) var selection: StreamInfo.Selection?
    /// Where playback begins (e.g. resuming from history).
    var startPosition: Double = 0
    /// The quality the user picked for this video (defaults to the preference).
    private(set) var quality: VideoQuality

    @ObservationIgnored private let resolver: StreamResolver
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "Player")

    init(video: Video, resolver: StreamResolver, preferences: Preferences, client: InnerTubeClient,
         isSignedIn: @escaping () -> Bool) {
        self.video = video
        self.page = WatchPageModel(videoId: video.id, client: client, isSignedIn: isSignedIn)
        self.resolver = resolver
        self.prefs = preferences
        self.quality = preferences.quality
        self.player = MPVPlayer(options: .init(
            hardwareDecoding: preferences.hardwareDecoding,
            bufferMB: preferences.bufferMB,
            speed: preferences.defaultSpeed
        ))
        let player = self.player
        self.sponsor = SponsorSkipper(
            actions: { [preferences] in preferences.sponsorAction(for: $0) },
            showNotice: preferences.showSkipNotice,
            seek: { [weak player] in player?.seek(to: $0) }
        )
        let sponsor = self.sponsor
        player.onTimeChange = { [weak sponsor] in sponsor?.timeChanged($0) }
        player.onLoadFailure = { [weak self] message in self?.recoverFromLoadFailure(message) }
    }

    func start() {
        loadTask?.cancel()
        phase = .resolving
        loadSponsorSegments()
        Task { [page] in await page.load() }
        loadTask = Task {
            let start = ContinuousClock.now
            do {
                let info = try await resolver.resolve(video.id, isLive: video.kind == .live)
                try Task.checkCancellation()
                self.info = info
                log.info("Streams ready for \(self.video.id, privacy: .public) after \(ContinuousClock.now - start, privacy: .public)")
                try await play(info, at: startPosition, autoplay: prefs.autoplay)
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
        let (position, playing) = (player.position, !player.isPaused)
        loadTask?.cancel()
        loadTask = Task { try? await play(info, at: position, autoplay: playing) }
    }

    /// Qualities this video actually offers.
    var availableQualities: [VideoQuality] {
        let heights = Set(info?.formats.filter(\.hasVideo).compactMap(\.height) ?? [])
        return VideoQuality.allCases.filter { q in q == .auto || heights.contains(q.rawValue) }
    }

    func retry() {
        failedLoads = 0
        Task { await resolver.invalidate(video.id) }
        start()
    }

    @ObservationIgnored private var failedLoads = 0

    /// mpv couldn't open the streams before playing anything (e.g. 403). Retry the same
    /// links twice, then fetch fresh ones once, before showing an error.
    private func recoverFromLoadFailure(_ message: String) {
        guard let info else { return }
        failedLoads += 1
        log.error("Load failed (attempt \(self.failedLoads)): \(message, privacy: .public)")
        let position = player.position
        switch failedLoads {
        case 1, 2:
            loadTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                try? await play(info, at: position, autoplay: true)
            }
        case 3:
            loadTask = Task {
                await resolver.invalidate(video.id)
                phase = .resolving
                do {
                    let fresh = try await resolver.resolve(video.id, isLive: video.kind == .live)
                    self.info = fresh
                    try await play(fresh, at: position, autoplay: true)
                } catch is CancellationError {
                } catch {
                    phase = .failed(error.localizedDescription)
                }
            }
        default:
            phase = .failed("YouTube refused the stream (\(message)). Try again in a moment.")
            player.fail(message)
        }
    }

    func close() {
        loadTask?.cancel()
        player.stop()
    }

    /// Runs alongside stream resolution so it never delays playback.
    private func loadSponsorSegments() {
        guard prefs.sponsorBlockEnabled, video.kind == .video || video.kind == .short else { return }
        let categories = SponsorCategory.allCases.filter { prefs.sponsorAction(for: $0) != .ignore }
        let server = prefs.sponsorBlockServer
        let id = video.id
        Task {
            do {
                let segments = try await SponsorBlockAPI.segments(for: id, categories: categories, server: server)
                sponsor.setSegments(segments)
                if !segments.isEmpty { log.info("SponsorBlock: \(segments.count) segment(s) for \(id, privacy: .public)") }
            } catch {
                log.error("SponsorBlock failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func play(_ info: StreamInfo, at time: Double, autoplay: Bool) async throws {
        guard let selection = info.select(quality: quality, codec: prefs.codec) else {
            phase = .failed("No playable stream was found for this video.")
            return
        }
        self.selection = selection
        // Fresh links 403 until YouTube's embargo passes (usually ~4s after extraction).
        // Hover prefetch and the cache normally put us past it already.
        if let ready = selection.availableAt, ready > .now {
            let wait = ready.timeIntervalSinceNow + 0.25
            log.info("Waiting \(wait, format: .fixed(precision: 1), privacy: .public)s for YouTube's stream embargo")
            try await Task.sleep(for: .seconds(wait))
        }
        log.info("Playing \(selection.video.id, privacy: .public) \(selection.video.height ?? 0)p \(selection.video.vcodec ?? "", privacy: .public) + \(selection.audio?.id ?? "muxed", privacy: .public)")
        player.load(selection, startAt: time, autoplay: autoplay)
        phase = .ready
    }
}
