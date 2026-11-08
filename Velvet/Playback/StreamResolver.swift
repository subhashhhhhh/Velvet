import Foundation
import OSLog

/// Turns a video ID into playable stream links by running yt-dlp.
///
/// yt-dlp + the JS runtime are short-lived child processes: they start, resolve,
/// and exit, so their memory never sticks to Velvet. Results are cached until
/// YouTube's links expire, and in-flight resolves are shared.
actor StreamResolver {
    private let tools: ToolManager
    private let preferences: Preferences
    private let session: @Sendable () async -> YouTubeSession?
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Resolver")

    private var cache: [String: StreamInfo] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<StreamInfo, Error>] = [:]
    /// At most one speculative (hover) resolve runs at a time.
    private var prefetch: (id: String, task: Task<StreamInfo, Error>)?
    private static let cacheLimit = 40

    static let cacheDir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "com.subhash.Velvet/yt-dlp", directoryHint: .isDirectory)

    init(tools: ToolManager, preferences: Preferences, session: @escaping @Sendable () async -> YouTubeSession?) {
        self.tools = tools
        self.preferences = preferences
        self.session = session
    }

    func cached(_ videoId: String) -> StreamInfo? {
        guard let info = cache[videoId], !info.isExpired else { return nil }
        return info
    }

    /// Resolves `videoId`, reusing a cached or in-progress result when possible.
    func resolve(_ videoId: String, isLive: Bool = false) async throws -> StreamInfo {
        if let hit = cached(videoId) { return hit }
        if let running = inFlight[videoId] { return try await running.value }
        if let p = prefetch, p.id == videoId {
            prefetch = nil
            inFlight[videoId] = p.task
            defer { inFlight[videoId] = nil }
            return try await p.task.value
        }
        let task = makeTask(videoId, isLive: isLive)
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        return try await task.value
    }

    /// Speculatively resolves a video (e.g. on hover). Replaces any older prefetch.
    func prefetch(_ videoId: String, isLive: Bool = false) {
        guard cached(videoId) == nil, inFlight[videoId] == nil, prefetch?.id != videoId else { return }
        prefetch?.task.cancel() // terminates the old yt-dlp process
        prefetch = (videoId, makeTask(videoId, isLive: isLive))
    }

    func invalidate(_ videoId: String) {
        cache[videoId] = nil
    }

    private func makeTask(_ videoId: String, isLive: Bool) -> Task<StreamInfo, Error> {
        Task {
            let info = try await self.run(videoId, isLive: isLive)
            self.store(info)
            return info
        }
    }

    private func store(_ info: StreamInfo) {
        cache[info.videoId] = info
        cacheOrder.removeAll { $0 == info.videoId }
        cacheOrder.append(info.videoId)
        while cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    // MARK: - yt-dlp

    /// Two strategies, fastest first:
    /// - `fast`: the visionOS client, no cookies. ~2s, full quality (4K VP9/AV1), and no
    ///   stream embargo — its links work immediately. Your session isn't sent at all.
    /// - `account`: yt-dlp's default clients with your cookies, for videos that need an
    ///   account (age-restricted, members-only, private). Slower, and its links are
    ///   embargoed ~4s (PlayerSession waits that out).
    private enum Strategy: String { case fast, account }

    private func run(_ videoId: String, isLive: Bool) async throws -> StreamInfo {
        do {
            let info = try await run(videoId, isLive: isLive, strategy: .fast)
            // Opened from somewhere that didn't know it was live (related video, link): the
            // HLS-skipping fast path then returns no playable formats. Retry with HLS.
            if info.isLive && !isLive && !info.formats.contains(where: { $0.isHLS }) {
                log.info("\(videoId, privacy: .public) is live; resolving again with HLS")
                return try await run(videoId, isLive: true, strategy: .fast)
            }
            return info
        } catch is CancellationError {
            throw CancellationError()
        } catch where !isLive && error.localizedDescription.localizedCaseInsensitiveContains("No video formats") {
            // A live stream opened unflagged: with HLS skipped it has no formats at all, so
            // yt-dlp errors out before we could see `is_live`. Retry with HLS.
            log.info("\(videoId, privacy: .public) has no non-HLS formats (likely live); resolving again with HLS")
            return try await run(videoId, isLive: true)
        } catch {
            log.info("Fast resolve failed for \(videoId, privacy: .public) (\(error.localizedDescription, privacy: .public)); retrying with account")
            return try await run(videoId, isLive: isLive, strategy: .account)
        }
    }

    private func run(_ videoId: String, isLive: Bool, strategy: Strategy) async throws -> StreamInfo {
        let runtime = await MainActor.run { preferences.jsRuntime }
        let paths = try await tools.ready(runtime: runtime)
        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)

        var args = [
            "--no-js-runtimes", "--js-runtimes", "\(Tool(runtime).runtimeName!):\(paths.runtime.path)",
            "--cache-dir", Self.cacheDir.path,
            "-J", "--no-playlist", "--no-warnings", "--no-progress", "--ignore-config",
        ]
        var extractorArgs: [String] = []
        // HLS manifests cost ~0.5–2s extra and are only needed for live streams.
        if !isLive { extractorArgs.append("skip=hls") }
        if strategy == .fast { extractorArgs.append("player_client=visionos") }
        if !extractorArgs.isEmpty { args += ["--extractor-args", "youtube:" + extractorArgs.joined(separator: ";")] }

        // Account strategy only: hand yt-dlp the session via a private temp file, removed right after.
        var cookieFile: URL?
        if strategy == .account, let session = await session() {
            let file = FileManager.default.temporaryDirectory.appending(path: "velvet-cookies-\(UUID().uuidString).txt")
            let contents = await session.netscapeCookieFile()
            FileManager.default.createFile(atPath: file.path, contents: Data(contents.utf8),
                                           attributes: [.posixPermissions: 0o600])
            cookieFile = file
            args += ["--cookies", file.path]
        }
        defer { if let cookieFile { try? FileManager.default.removeItem(at: cookieFile) } }

        args.append("https://www.youtube.com/watch?v=\(videoId)")

        let start = ContinuousClock.now
        let result = try await ProcessRunner.run(paths.ytdlp, arguments: args, timeout: .seconds(45))
        try Task.checkCancellation()
        guard result.status == 0 else {
            let message = Self.cleanError(result.stderrText)
            throw PlaybackRestriction(ytdlpError: message) ?? ProcessError.failed("yt-dlp", result.status, message)
        }
        let json = try JSON(data: result.stdout)
        guard let info = StreamInfo(ytdlp: json),
              info.isLive || info.formats.contains(where: { $0.hasVideo }) else {
            throw ProcessError.failed("yt-dlp", 0, "No playable formats were returned.")
        }
        log.info("Resolved \(videoId, privacy: .public) [\(strategy.rawValue, privacy: .public)]: \(info.formats.count) formats in \(ContinuousClock.now - start, privacy: .public)")
        return info
    }

    /// Keeps yt-dlp's last `ERROR:` line, which is the useful one.
    private static func cleanError(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map(String.init)
        if let error = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return String(error.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.last ?? "Unknown error"
    }
}

/// Videos YouTube won't play for this viewer, with a readable explanation instead of yt-dlp's.
nonisolated enum PlaybackRestriction: LocalizedError, Equatable {
    case membersOnly, ageRestricted, privateVideo, unavailable

    init?(ytdlpError message: String) {
        let m = message.lowercased()
        if m.contains("members-only") || m.contains("members only") || m.contains("join this channel") {
            self = .membersOnly
        } else if m.contains("confirm your age") || m.contains("age-restricted") || m.contains("inappropriate for some users") {
            self = .ageRestricted
        } else if m.contains("private video") {
            self = .privateVideo
        } else if m.contains("video unavailable") || m.contains("this video has been removed") {
            self = .unavailable
        } else {
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .membersOnly: "This video is for channel members only. Join the channel on YouTube to watch it here."
        case .ageRestricted: "This video is age-restricted. Sign in with an account that can watch it."
        case .privateVideo: "This video is private."
        case .unavailable: "This video isn't available anymore."
        }
    }

    var symbol: String {
        switch self {
        case .membersOnly: "star.circle"
        case .ageRestricted: "person.badge.shield.checkmark"
        case .privateVideo: "lock"
        case .unavailable: "video.slash"
        }
    }
}
