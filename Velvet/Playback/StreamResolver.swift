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
            return try await run(videoId, isLive: isLive, strategy: .fast)
        } catch is CancellationError {
            throw CancellationError()
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
            throw ProcessError.failed("yt-dlp", result.status, Self.cleanError(result.stderrText))
        }
        let json = try JSON(data: result.stdout)
        guard let info = StreamInfo(ytdlp: json),
              info.formats.contains(where: { $0.hasVideo }) else {
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
