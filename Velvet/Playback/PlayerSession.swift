import Foundation
import AppKit
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
    /// Reports viewing to YouTube (history, progress); nil when signed out.
    @ObservationIgnored private let tracker: WatchTracker?
    private(set) var phase: Phase = .resolving
    private(set) var info: StreamInfo?
    private(set) var selection: StreamInfo.Selection?
    /// Where playback begins (e.g. resuming from history).
    var startPosition: Double = 0
    /// Set when we auto-resumed, so the player can offer "Start Over".
    var resumedFrom: Double?
    @ObservationIgnored private let progress: WatchProgressStore
    /// The quality the user picked for this video (defaults to the preference).
    private(set) var quality: VideoQuality

    @ObservationIgnored private let resolver: StreamResolver
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "Player")

    init(video: Video, resolver: StreamResolver, preferences: Preferences, client: InnerTubeClient,
         session: YouTubeSession?, progress: WatchProgressStore, isSignedIn: @escaping () -> Bool) {
        self.video = video
        self.progress = progress
        self.tracker = session.map { WatchTracker(videoId: video.id, client: client, session: $0) }
        self.page = WatchPageModel(videoId: video.id, client: client, isSignedIn: isSignedIn)
        self.resolver = resolver
        self.prefs = preferences
        self.quality = preferences.quality
        self.player = MPVPlayer(options: .init(
            hardwareDecoding: preferences.hardwareDecoding,
            bufferMB: preferences.bufferMB,
            speed: video.kind == .short ? 1 : preferences.defaultSpeed,
            loop: video.kind == .short
        ))
        let player = self.player
        self.sponsor = SponsorSkipper(
            actions: { [preferences] in preferences.sponsorAction(for: $0) },
            showNotice: preferences.showSkipNotice,
            seek: { [weak player] in player?.seek(to: $0) }
        )
        let sponsor = self.sponsor
        let tracker = self.tracker
        var lastSaved = 0.0
        player.onTimeChange = { [weak self, weak sponsor, weak player] t in
            sponsor?.timeChanged(t)
            tracker?.timeChanged(t, isPlaying: !(player?.isPaused ?? true))
            if abs(t - lastSaved) >= 15 { lastSaved = t; self?.saveProgress() }
        }
        player.onPauseChange = { [weak self, weak player] paused in
            if paused { self?.noteLivePause() }
            guard paused, let t = player?.position else { return }
            tracker?.flush(at: t)
            self?.saveProgress()
        }
        player.onLoadFailure = { [weak self] message in self?.recoverFromLoadFailure(message) }
    }

    func start() {
        loadTask?.cancel()
        phase = .resolving
        loadSponsorSegments()
        Task { [page] in await page.load() }
        tracker?.prepare()
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
                restriction = error as? PlaybackRestriction
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

    /// Why YouTube won't play this video for us (members-only, private, …), when that's the failure.
    private(set) var restriction: PlaybackRestriction?

    // MARK: Chapters

    var chapters: [Chapter] { info?.chapters ?? [] }

    func chapter(at time: Double) -> Chapter? {
        chapters.last { $0.start <= time + 0.25 }
    }

    // MARK: Captions

    var captionTracks: [CaptionTrack] { info?.captions ?? [] }
    private(set) var selectedCaption: CaptionTrack?
    @ObservationIgnored private var captionTask: Task<Void, Never>?

    func selectCaption(_ track: CaptionTrack?) {
        captionTask?.cancel()
        selectedCaption = track
        guard let track else { player.hideCaptions(); return }
        let videoId = video.id
        captionTask = Task {
            do {
                let file = try await CaptionLoader.localFile(for: track, videoId: videoId)
                guard !Task.isCancelled, selectedCaption == track else { return }
                player.showCaptions(file: file, title: track.label, language: track.languageCode)
            } catch {
                log.error("Captions failed: \(error.localizedDescription, privacy: .public)")
                if selectedCaption == track { selectedCaption = nil }
            }
        }
    }

    /// C key: last-used / best track on, or off.
    func toggleCaptions() {
        selectCaption(selectedCaption == nil ? preferredCaption() ?? captionTracks.first : nil)
    }

    /// A manual track in the user's language, else the auto track if the video is in their language.
    private func preferredCaption() -> CaptionTrack? {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return captionTracks.first { !$0.isAutoGenerated && $0.languageCode.hasPrefix(lang) }
            ?? captionTracks.first { $0.isAutoGenerated && $0.id.hasSuffix("-orig") && $0.languageCode.hasPrefix(lang) }
    }

    /// Live according to the stream itself (cards don't always know).
    var isLive: Bool { info?.isLive ?? (video.kind == .live) }

    /// Set once the viewer pauses a live stream: playback is then behind the live edge.
    private(set) var isBehindLive = false

    /// Reloads the live stream at its current edge.
    func goLive() {
        guard isLive, let selection else { return }
        isBehindLive = false
        player.load(selection, startAt: 0, autoplay: true)
    }

    func noteLivePause() { if isLive { isBehindLive = true } }

    /// Qualities this video actually offers.
    var availableQualities: [VideoQuality] {
        let heights = Set(info?.formats.filter(\.hasVideo).compactMap(\.tier) ?? [])
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
                    restriction = error as? PlaybackRestriction
                phase = .failed(error.localizedDescription)
                }
            }
        default:
            phase = .failed("YouTube refused the stream (\(message)). Try again in a moment.")
            player.fail(message)
        }
    }

    // MARK: Suspend (a Short opened from this video's page)

    @ObservationIgnored private var suspendedAt: Double?
    @ObservationIgnored private var playOnResume = true

    /// Remembers the moment and unloads the stream, freeing its buffers while Shorts play.
    /// The page (comments, related) and the resolved stream links stay.
    func suspend() {
        let position = player.position
        suspendedAt = position
        playOnResume = !player.isPaused
        tracker?.flush(at: position, state: "paused")
        saveProgress()
        loadTask?.cancel()
        player.stop()
    }

    /// Picks up where `suspend()` left off: the same links if they're still fresh (no yt-dlp
    /// run), else newly resolved ones. Live streams rejoin at the live edge.
    func resume() {
        guard let at = suspendedAt else { return }
        suspendedAt = nil
        if isLive { goLive(); return }
        guard case .ready = phase, let info else {
            // It never finished loading: start again from the remembered spot.
            startPosition = at
            start()
            return
        }
        let autoplay = playOnResume
        loadTask = Task {
            var streams = info
            if info.isExpired {
                // Only the links are stale; the page stays as it is.
                await resolver.invalidate(video.id)
                guard let fresh = try? await resolver.resolve(video.id, isLive: false) else {
                    phase = .failed("Couldn't reload this video. Try again in a moment.")
                    return
                }
                self.info = fresh
                streams = fresh
            }
            try? await play(streams, at: at, autoplay: autoplay)
        }
    }

    func close() {
        page.stopLiveChat()
        tracker?.flush(at: player.position, state: "paused")
        saveProgress()
        loadTask?.cancel()
        player.stop()
    }

    /// Tallest useful video height for the largest connected screen: a 16:9 video fit to the
    /// screen's pixel width (e.g. 2880×1800 → 1620, so 1440p is the most worth decoding).
    static func displayHeightLimit() -> Int {
        let screens = NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor,
                                                    height: $0.frame.height * $0.backingScaleFactor) }
        guard let biggest = screens.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return 1440 }
        return Int(min(biggest.height, biggest.width * 9 / 16))
    }

    /// Remembers the position locally (live streams have no meaningful position).
    func saveProgress() {
        guard video.kind != .live, player.duration > 0, player.position > 0 else { return }
        progress.record(video.id, position: player.position, duration: player.duration)
    }

    /// Restart from the beginning after an automatic resume.
    func startOver() {
        resumedFrom = nil
        player.seek(to: 0)
        player.play()
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
        guard let selection = info.select(quality: quality, codec: prefs.codec, displayLimit: Self.displayHeightLimit()) else {
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
        log.info("Starting at \(time, format: .fixed(precision: 1), privacy: .public)s\(self.resumedFrom != nil ? " (resumed)" : "", privacy: .public)")
        log.info("Playing \(selection.video.id, privacy: .public) \(selection.video.resolutionLabel, privacy: .public) \(selection.video.vcodec ?? "", privacy: .public) + \(selection.audio?.id ?? "muxed", privacy: .public)")
        player.load(selection, startAt: time, autoplay: autoplay)
        phase = .ready
        log.debug("Captions: \(info.captions.map(\.id), privacy: .public)")
        // Re-apply captions after a (re)load; first load honours the auto-captions preference.
        if let current = selectedCaption {
            selectCaption(current)
        } else if prefs.autoCaptions, !isLive, let track = preferredCaption() {
            selectCaption(track)
        }
    }
}
