import AppKit
import MediaPlayer
import OSLog

nonisolated private let log = Logger(subsystem: "com.subhash.Velvet", category: "NowPlaying")

/// Publishes the current video to Control Center / the menu bar Now Playing widget and
/// handles media keys (play/pause, ±10s, scrubbing) via MPRemoteCommandCenter.
///
/// Only runs while a video is open: a 1 s check publishes pause, rate, duration and seek
/// changes. The system extrapolates elapsed time between updates, so this stays cheap.
final class NowPlaying {
    private let current: () -> PlayerSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    private var published: (id: String, paused: Bool, rate: Double, duration: Double, elapsed: Double, at: Date)?
    private var artworkFor: String?

    private var center: MPNowPlayingInfoCenter { .default() }

    init(current: @escaping () -> PlayerSession?) {
        self.current = current
    }

    func start() {
        registerCommands()
        observe()
    }

    // MARK: - Tracking the active video

    private func observe() {
        let session = withObservationTracking { current() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        if session != nil {
            if task == nil {
                task = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.publish()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            } else {
                publish()
            }
        } else {
            task?.cancel(); task = nil
            published = nil; artworkFor = nil
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
    }

    private func publish() {
        guard let session = current() else { return }
        let player = session.player
        let id = session.video.id
        let paused = player.isPaused || player.hasEnded
        let rate = paused ? 0 : player.speed
        let now = Date()

        if let p = published, p.id == id, p.paused == paused, p.rate == rate, p.duration == player.duration {
            let expected = p.elapsed + now.timeIntervalSince(p.at) * p.rate
            if abs(expected - player.position) < 1.5 { return }
        }

        var info = center.nowPlayingInfo ?? [:]
        if published?.id != id { info = [:] }
        info[MPMediaItemPropertyTitle] = session.video.title
        info[MPMediaItemPropertyArtist] = session.video.channelName ?? session.info?.channel ?? ""
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = session.isLive
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if !session.isLive {
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
        }
        center.nowPlayingInfo = info
        center.playbackState = paused ? .paused : .playing
        published = (id, paused, rate, player.duration, player.position, now)

        if artworkFor != id {
            artworkFor = id
            loadArtwork(for: session.video)
        }
    }

    private func loadArtwork(for video: Video) {
        let url = video.thumbnail(minWidth: 480)
        Task { [weak self] in
            guard let data = await ImagePipeline.shared.data(for: url), let image = NSImage(data: data),
                  let self, self.artworkFor == video.id else { return }
            let artwork = Self.artwork(image)
            var info = self.center.nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            self.center.nowPlayingInfo = info
        }
    }

    /// MediaPlayer asks for the image on its own queue, so this must not be main-actor isolated.
    private nonisolated static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    // MARK: - Media keys / remote commands

    /// Handlers may be called off the main thread; hop to it (the status is informational).
    private func perform(_ action: @escaping @MainActor (PlayerSession) -> Void) {
        guard let session = current() else { return }
        action(session)
        published = nil
        publish()
    }

    private func registerCommands() {
        let c = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPVPlayer, PlayerSession) -> Void) {
            command.isEnabled = true
            command.addTarget { @Sendable [weak self] event in
                log.debug("Remote command \(String(describing: type(of: event.command)), privacy: .public)")
                Task { @MainActor in self?.perform { action($0.player, $0) } }
                return .success
            }
        }
        on(c.playCommand) { p, _ in p.play() }
        on(c.pauseCommand) { p, _ in p.pause() }
        on(c.togglePlayPauseCommand) { p, _ in p.togglePause() }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        on(c.skipForwardCommand) { p, s in if !s.isLive { p.seek(by: 10) } }
        on(c.skipBackwardCommand) { p, s in if !s.isLive { p.seek(by: -10) } }
        c.changePlaybackPositionCommand.isEnabled = true
        c.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.perform { if !$0.isLive { $0.player.seek(to: time) } } }
            return .success
        }
    }
}
