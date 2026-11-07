import Foundation
import OSLog

/// Supplies per-request auth headers (Cookie, Authorization: SAPISIDHASH …) once signed in.
nonisolated protocol InnerTubeAuthProvider: Sendable {
    func headers(origin: String) async -> [String: String]
    /// Receives each response's headers so rotated cookies can be kept.
    func absorb(responseHeaders: [String: String], url: URL) async
}

nonisolated enum InnerTubeError: LocalizedError {
    case http(Int, String)
    case bootstrap

    var errorDescription: String? {
        switch self {
        case .http(let code, let endpoint): "YouTube returned HTTP \(code) for \(endpoint)."
        case .bootstrap: "Couldn't read YouTube's client configuration."
        }
    }
}

/// Talks to YouTube's internal `youtubei/v1` API as the WEB client.
actor InnerTubeClient {
    static let origin = "https://www.youtube.com"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Values scraped from youtube.com that every request must echo back.
    struct Config: Codable, Sendable {
        var clientVersion: String
        var visitorData: String?
        var fetchedAt: Date
    }

    private static let fallbackVersion = "2.20261105.05.01"
    private static let configKey = "InnerTube.config"
    private static let configLifetime: TimeInterval = 12 * 60 * 60

    private let session: URLSession
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "InnerTube")
    private var config: Config?
    private var bootstrapTask: Task<Config, Error>?
    private var auth: (any InnerTubeAuthProvider)?

    let language: String
    let region: String

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        // Cookies are managed explicitly (see auth provider), never by URLSession.
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Language": "en-US,en;q=0.9"]
        session = URLSession(configuration: cfg)
        language = "en"
        region = Locale.current.region?.identifier ?? "US"

        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(Config.self, from: data) {
            config = saved
        }
    }

    func setAuth(_ provider: (any InnerTubeAuthProvider)?) {
        auth = provider
    }

    var isSignedIn: Bool { auth != nil }

    // MARK: - Endpoints

    func browse(_ browseId: String, params: String? = nil) async throws -> JSON {
        var body: [String: JSON] = ["browseId": .string(browseId)]
        if let params { body["params"] = .string(params) }
        return try await post("browse", body)
    }

    func browse(continuation token: String) async throws -> JSON {
        try await post("browse", ["continuation": .string(token)])
    }

    func search(_ query: String, params: String? = nil) async throws -> JSON {
        var body: [String: JSON] = ["query": .string(query)]
        if let params { body["params"] = .string(params) }
        return try await post("search", body)
    }

    func search(continuation token: String) async throws -> JSON {
        try await post("search", ["continuation": .string(token)])
    }

    /// Watch-page data: title/description, channel, related videos, comment tokens.
    func next(videoId: String) async throws -> JSON {
        try await post("next", ["videoId": .string(videoId)])
    }

    func next(continuation token: String) async throws -> JSON {
        try await post("next", ["continuation": .string(token)])
    }

    // MARK: - Shorts

    /// A first Short chosen by YouTube, plus the token for the rest of its sequence.
    func shortsSeedless() async throws -> JSON {
        try await post("reel/reel_item_watch", ["inputType": "REEL_WATCH_INPUT_TYPE_SEEDLESS", "params": "CA8%3D"])
    }

    /// The next Shorts in a sequence (token from `shortsSeedless`, `shortsSeed(for:)` or a previous page).
    func shortsSequence(_ token: String) async throws -> JSON {
        try await post("reel/reel_watch_sequence", ["sequenceParams": .string(token)])
    }

    /// Sequence token that starts from a specific Short: protobuf `{3: {1: videoId, 3: 0, 4: 1}}`.
    nonisolated static func shortsSeed(for videoId: String) -> String {
        let id = Array(videoId.utf8)
        let inner: [UInt8] = [0x0A, UInt8(id.count)] + id + [0x18, 0x00, 0x20, 0x01]
        return Data([0x1A, UInt8(inner.count)] + inner).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - Account actions

    func like(_ videoId: String) async throws { _ = try await post("like/like", ["target": ["videoId": .string(videoId)]]) }
    func dislike(_ videoId: String) async throws { _ = try await post("like/dislike", ["target": ["videoId": .string(videoId)]]) }
    func removeLike(_ videoId: String) async throws { _ = try await post("like/removelike", ["target": ["videoId": .string(videoId)]]) }

    /// Your playlists (Watch Later first) and whether each contains `videoId`.
    func playlistOptions(for videoId: String) async throws -> JSON {
        try await post("playlist/get_add_to_playlist", ["videoIds": [.string(videoId)], "excludeWatchLater": false])
    }

    /// Adds or removes a video from a playlist; "WL" is Watch Later.
    func setVideo(_ videoId: String, inPlaylist playlistId: String, _ included: Bool) async throws {
        let action: JSON = included
            ? ["action": "ACTION_ADD_VIDEO", "addedVideoId": .string(videoId)]
            : ["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", "removedVideoId": .string(videoId)]
        _ = try await post("browse/edit_playlist", ["playlistId": .string(playlistId), "actions": [action]])
    }

    /// The signed-in account's name, handle and photo.
    func accountMenu() async throws -> JSON {
        try await post("account/account_menu", [:])
    }

    // MARK: - Transport

    func post(_ endpoint: String, _ body: [String: JSON]) async throws -> JSON {
        let cfg = try await currentConfig()

        var client: [String: JSON] = [
            "clientName": "WEB",
            "clientVersion": .string(cfg.clientVersion),
            "hl": .string(language),
            "gl": .string(region),
            "userAgent": .string(Self.userAgent),
        ]
        if let vd = cfg.visitorData { client["visitorData"] = .string(vd) }

        var payload = body
        payload["context"] = ["client": .object(client)]

        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSON.object(payload).data()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(cfg.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        if let vd = cfg.visitorData { request.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let auth {
            for (k, v) in await auth.headers(origin: Self.origin) { request.setValue(v, forHTTPHeaderField: k) }
        } else {
            request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie") // skip EU consent wall
        }

        let start = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if let auth, let http, let headers = http.allHeaderFields as? [String: String], let url = http.url {
            await auth.absorb(responseHeaders: headers, url: url)
        }
        let target = body["browseId"]?.string ?? body["videoId"]?.string ?? (body["continuation"] != nil ? "continuation" : "")
        log.debug("\(endpoint, privacy: .public) \(target, privacy: .public) \(status) \(data.count)B in \(ContinuousClock.now - start, privacy: .public)")
        guard (200..<300).contains(status) else { throw InnerTubeError.http(status, endpoint) }
        return try JSON(data: data)
    }

    // MARK: - Bootstrap

    private func currentConfig() async throws -> Config {
        if let config, Date().timeIntervalSince(config.fetchedAt) < Self.configLifetime {
            return config
        }
        if let bootstrapTask { return try await bootstrapTask.value }

        let task = Task { try await self.fetchConfig() }
        bootstrapTask = task
        defer { bootstrapTask = nil }
        do {
            let fresh = try await task.value
            config = fresh
            if let data = try? JSONEncoder().encode(fresh) {
                UserDefaults.standard.set(data, forKey: Self.configKey)
            }
            return fresh
        } catch {
            log.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
            // A stale config usually still works; a hard-coded one is the last resort.
            if let config { return config }
            return Config(clientVersion: Self.fallbackVersion, visitorData: nil, fetchedAt: .distantPast)
        }
    }

    private func fetchConfig() async throws -> Config {
        var request = URLRequest(url: URL(string: Self.origin)!)
        if let auth {
            for (k, v) in await auth.headers(origin: Self.origin) { request.setValue(v, forHTTPHeaderField: k) }
        } else {
            request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        }
        let (data, _) = try await session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)

        guard let version = Self.capture("\"INNERTUBE_CLIENT_VERSION\":\"([^\"]+)\"", in: html) else {
            throw InnerTubeError.bootstrap
        }
        let visitor = Self.capture("\"VISITOR_DATA\":\"([^\"]+)\"", in: html)
        log.info("Bootstrapped WEB client \(version, privacy: .public)")
        return Config(clientVersion: version, visitorData: visitor, fetchedAt: .now)
    }

    /// Forces a fresh bootstrap on the next request (e.g. after signing in or out).
    func invalidateConfig() {
        config = nil
        UserDefaults.standard.removeObject(forKey: Self.configKey)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
