import Foundation
import OSLog

/// Reports viewing to YouTube the way youtube.com does, so videos watched in Velvet land in
/// your history, show progress bars / resume points, and inform recommendations.
///
/// - The WEB `player` response carries two tracking URLs.
/// - `videostatsPlaybackUrl` is pinged once real playback begins (registers the view + history).
/// - `videostatsWatchtimeUrl` is pinged every ~30s while playing and on pause/close, with the
///   watched segment (`st`→`et`) and current position (`cmt`), which drives resume progress.
final class WatchTracker {
    private let videoId: String
    private let client: InnerTubeClient
    private let session: YouTubeSession
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Tracking")
    private let http: URLSession

    private var playbackURL: URL?
    private var watchtimeURL: URL?
    private var duration: Double?
    /// Client playback nonce: one random ID per viewing, as youtube.com generates.
    private let cpn: String = {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String((0..<16).map { _ in alphabet[Int.random(in: 0...255) & 63] })
    }()

    private var startedPlayback = false
    private var lastReported: Double?
    private var lastPingAt = Date.distantPast
    private var playedSeconds: Double = 0
    private var lastTime: Double?
    private var setupTask: Task<Void, Never>?

    private static let pingInterval: TimeInterval = 30
    /// Don't count a view (or write history) for videos abandoned within a few seconds.
    private static let minimumPlay: Double = 3

    init(videoId: String, client: InnerTubeClient, session: YouTubeSession) {
        self.videoId = videoId
        self.client = client
        self.session = session
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpAdditionalHeaders = ["User-Agent": InnerTubeClient.userAgent]
        http = URLSession(configuration: cfg)
    }

    /// Fetches the tracking URLs (signed-in WEB player response). Runs alongside playback setup.
    func prepare() {
        setupTask = Task {
            do {
                let json = try await client.post("player", ["videoId": .string(videoId),
                                                            "contentCheckOk": true, "racyCheckOk": true])
                let tracking = json["playbackTracking"]
                playbackURL = tracking["videostatsPlaybackUrl"]["baseUrl"].string.flatMap(URL.init(string:))
                watchtimeURL = tracking["videostatsWatchtimeUrl"]["baseUrl"].string.flatMap(URL.init(string:))
                duration = json["videoDetails"]["lengthSeconds"].double
                if playbackURL == nil { log.info("No tracking URLs for \(self.videoId, privacy: .public)") }
            } catch {
                log.error("Tracking setup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Feed every playback time update (main actor, ~frame rate; cheap when nothing is due).
    func timeChanged(_ t: Double, isPlaying: Bool) {
        if let last = lastTime, isPlaying, t > last, t - last < 2 { playedSeconds += t - last }
        lastTime = t
        guard playbackURL != nil else { return }

        if !startedPlayback {
            guard playedSeconds >= Self.minimumPlay else { return }
            startedPlayback = true
            ping(playbackURL!, extra: ["cmt": fmt(t)])
            lastReported = max(0, t - playedSeconds)
            lastPingAt = .now
            return
        }
        if isPlaying, Date().timeIntervalSince(lastPingAt) >= Self.pingInterval {
            reportWatchtime(at: t, state: "playing")
        }
    }

    /// Pause, seek away, quality switch or close: flush the watched segment now.
    func flush(at t: Double, state: String = "paused") {
        guard startedPlayback else { return }
        reportWatchtime(at: t, state: state)
    }

    private func reportWatchtime(at t: Double, state: String) {
        guard let url = watchtimeURL else { return }
        let start = lastReported ?? 0
        // Seeking backwards starts a fresh segment rather than reporting a negative one.
        let st = start <= t ? start : t
        ping(url, extra: ["cmt": fmt(t), "st": fmt(st), "et": fmt(t), "state": state])
        lastReported = t
        lastPingAt = .now
    }

    private func ping(_ base: URL, extra: [String: String]) {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        var items = components.queryItems ?? []
        var params = ["ver": "2", "cpn": cpn, "el": "detailpage"]
        if let duration { params["len"] = fmt(duration) }
        params.merge(extra) { $1 }
        items.removeAll { params[$0.name] != nil }
        items += params.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        guard let url = components.url else { return }

        Task { [http, session, log, videoId] in
            var request = URLRequest(url: url)
            for (k, v) in await session.headers(origin: InnerTubeClient.origin) { request.setValue(v, forHTTPHeaderField: k) }
            do {
                let (_, response) = try await http.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                log.debug("\(url.path(), privacy: .public) \(videoId, privacy: .public) cmt=\(extra["cmt"] ?? "", privacy: .public) → \(code)")
            } catch {
                log.error("Tracking ping failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func fmt(_ t: Double) -> String { String(format: "%.3f", max(0, t)) }
}
