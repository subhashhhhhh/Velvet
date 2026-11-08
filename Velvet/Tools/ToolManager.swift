import Foundation
import CryptoKit
import OSLog

/// External helpers Velvet downloads and keeps updated.
nonisolated enum Tool: String, CaseIterable, Codable, Sendable, Identifiable {
    case ytdlp = "yt-dlp", deno, bun, quickjs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ytdlp: "yt-dlp"
        case .deno: "Deno"
        case .bun: "Bun"
        case .quickjs: "QuickJS"
        }
    }

    var repo: String {
        switch self {
        case .ytdlp: "yt-dlp/yt-dlp"
        case .deno: "denoland/deno"
        case .bun: "oven-sh/bun"
        case .quickjs: "quickjs-ng/quickjs"
        }
    }

    /// Apple-silicon release asset (macOS 27 is Apple-silicon only).
    var assetName: String {
        switch self {
        // The folder ("onedir") build starts in ~0.4s; the single-file one unpacks itself every run (~5s).
        case .ytdlp: "yt-dlp_macos.zip"
        case .deno: "deno-aarch64-apple-darwin.zip"
        case .bun: "bun-darwin-aarch64.zip"
        case .quickjs: "qjs-darwin-arm64"
        }
    }

    var isZip: Bool { assetName.hasSuffix(".zip") }

    /// Executable path inside the tool's install folder.
    var executablePath: String {
        switch self {
        case .ytdlp: "yt-dlp_macos"
        case .deno: "deno"
        case .bun: "bun-darwin-aarch64/bun"
        case .quickjs: "qjs"
        }
    }

    /// yt-dlp's `--js-runtimes` name.
    var runtimeName: String? {
        switch self {
        case .ytdlp: nil
        case .deno: "deno"
        case .bun: "bun"
        case .quickjs: "quickjs"
        }
    }

    init(_ runtime: JSRuntime) {
        switch runtime {
        case .deno: self = .deno
        case .bun: self = .bun
        case .quickjs: self = .quickjs
        }
    }
}

nonisolated enum ToolError: LocalizedError {
    case noAsset(String), checksumMismatch(String), missingExecutable(String), github(Int)

    var errorDescription: String? {
        switch self {
        case .noAsset(let name): "No download found for \(name)."
        case .checksumMismatch(let name): "\(name) download was corrupted (checksum mismatch)."
        case .missingExecutable(let name): "\(name) installed but its executable is missing."
        case .github(let code): "GitHub returned HTTP \(code)."
        }
    }
}

/// Downloads, verifies, installs and updates yt-dlp and the JavaScript runtimes.
@Observable
final class ToolManager {
    enum Status: Equatable {
        case notInstalled
        case working(String)
        case installed(version: String)
        case failed(String)
    }

    private(set) var status: [Tool: Status] = [:]
    private(set) var lastUpdateCheck: Date?

    nonisolated static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "com.subhash.Velvet/tools", directoryHint: .isDirectory)

    private var manifest: [Tool: InstalledTool] = [:]
    private var installs: [Tool: Task<URL, Error>] = [:]
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Tools")
    private static let lastCheckKey = "tools.lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    nonisolated struct InstalledTool: Codable, Sendable {
        var version: String
        var installedAt: Date
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        manifest = Self.loadManifest()
        for tool in Tool.allCases {
            if let m = manifest[tool], FileManager.default.isExecutableFile(atPath: executable(for: tool).path) {
                status[tool] = .installed(version: m.version)
            } else {
                status[tool] = .notInstalled
            }
        }
        lastUpdateCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    func executable(for tool: Tool) -> URL {
        Self.root.appending(path: tool.rawValue).appending(path: tool.executablePath)
    }

    func isInstalled(_ tool: Tool) -> Bool {
        if case .installed = status[tool] { return true }
        return false
    }

    /// Paths to yt-dlp and the chosen runtime, installing either on first use.
    func ready(runtime: JSRuntime) async throws -> (ytdlp: URL, runtime: URL) {
        async let y = ensureInstalled(.ytdlp)
        async let r = ensureInstalled(Tool(runtime))
        return try await (y, r)
    }

    @discardableResult
    func ensureInstalled(_ tool: Tool) async throws -> URL {
        if isInstalled(tool) { return executable(for: tool) }
        return try await install(tool)
    }

    /// Installs (or reinstalls) the latest release. Concurrent calls share one download.
    @discardableResult
    func install(_ tool: Tool) async throws -> URL {
        if let running = installs[tool] { return try await running.value }
        let task = Task { try await performInstall(tool) }
        installs[tool] = task
        defer { installs[tool] = nil }
        return try await task.value
    }

    /// Daily (or forced) check; updates yt-dlp and any installed runtime that's out of date.
    func checkForUpdates(force: Bool = false) async {
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < Self.checkInterval { return }
        lastUpdateCheck = .now
        UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey)

        for tool in Tool.allCases where isInstalled(tool) {
            do {
                let release = try await Self.latestRelease(tool)
                guard release.tag != manifest[tool]?.version else { continue }
                log.info("Updating \(tool.rawValue, privacy: .public) \(self.manifest[tool]?.version ?? "?", privacy: .public) → \(release.tag, privacy: .public)")
                try await install(tool)
            } catch {
                log.error("Update check failed for \(tool.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Install pipeline

    private func performInstall(_ tool: Tool) async throws -> URL {
        let previous = status[tool]
        do {
            status[tool] = .working("Checking latest release…")
            let release = try await Self.latestRelease(tool)

            status[tool] = .working("Downloading \(release.tag)…")
            let downloaded = try await Self.download(release.url)
            defer { try? FileManager.default.removeItem(at: downloaded) }

            status[tool] = .working("Verifying…")
            try await Self.verify(downloaded, digest: release.digest, name: tool.displayName)

            status[tool] = .working("Installing…")
            try await Self.unpack(downloaded, tool: tool)

            let exe = executable(for: tool)
            guard FileManager.default.isExecutableFile(atPath: exe.path) else {
                throw ToolError.missingExecutable(tool.displayName)
            }
            manifest[tool] = InstalledTool(version: release.tag, installedAt: .now)
            Self.saveManifest(manifest)
            status[tool] = .installed(version: release.tag)
            log.info("Installed \(tool.rawValue, privacy: .public) \(release.tag, privacy: .public)")

            // First launch of fresh binaries is slow while macOS scans them; pay that now, not on first play.
            Task.detached(priority: .utility) {
                _ = try? await ProcessRunner.run(exe, arguments: ["--version"], timeout: .seconds(60))
            }
            return exe
        } catch {
            log.error("Install of \(tool.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            // Keep a working older install usable if an update fails.
            if case .installed = previous, FileManager.default.isExecutableFile(atPath: executable(for: tool).path) {
                status[tool] = previous
            } else {
                status[tool] = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    nonisolated struct Release: Sendable {
        let tag: String
        let url: URL
        let digest: String?
    }

    /// GitHub's API and download CDN sometimes answer 502/503/504 or drop the connection for a
    /// few seconds. Retry those (1 s, 3 s, 7 s) instead of leaving the tools uninstalled.
    @concurrent
    nonisolated static func retrying<T: Sendable>(_ what: String, _ body: @Sendable () async throws -> T) async throws -> T {
        let delays: [Duration] = [.seconds(1), .seconds(3), .seconds(7)]
        for attempt in 0... {
            do {
                return try await body()
            } catch let error where attempt < delays.count && isTransient(error) {
                Logger(subsystem: "com.subhash.Velvet", category: "Tools")
                    .info("\(what, privacy: .public) failed (\(error.localizedDescription, privacy: .public)); retrying")
                try await Task.sleep(for: delays[attempt])
            }
        }
        fatalError("unreachable")
    }

    private nonisolated static func isTransient(_ error: Error) -> Bool {
        if case ToolError.github(let code) = error { return code == 0 || code == 429 || code >= 500 }
        if let url = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed].contains(url.code)
        }
        return false
    }

    @concurrent
    nonisolated static func latestRelease(_ tool: Tool) async throws -> Release {
        try await retrying("Release lookup for \(tool.rawValue)") { try await fetchLatestRelease(tool) }
    }

    @concurrent
    private nonisolated static func fetchLatestRelease(_ tool: Tool) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(tool.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Velvet", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ToolError.github(code) }
        let json = try JSON(data: data)
        guard let tag = json["tag_name"].string,
              let asset = json["assets"].array.first(where: { $0["name"].string == tool.assetName }),
              let url = asset["browser_download_url"].string.flatMap(URL.init(string:)) else {
            throw ToolError.noAsset(tool.displayName)
        }
        return Release(tag: tag, url: url, digest: asset["digest"].string)
    }

    @concurrent
    private nonisolated static func download(_ url: URL) async throws -> URL {
        try await retrying("Download of \(url.lastPathComponent)") { try await downloadOnce(url) }
    }

    @concurrent
    private nonisolated static func downloadOnce(_ url: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ToolError.github(code) }
        // The system deletes `temp` once we return; move it somewhere we own.
        let owned = FileManager.default.temporaryDirectory.appending(path: "velvet-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: temp, to: owned)
        return owned
    }

    @concurrent
    private nonisolated static func verify(_ file: URL, digest: String?, name: String) async throws {
        guard let digest, digest.hasPrefix("sha256:") else { return } // older releases lack digests
        let expected = String(digest.dropFirst("sha256:".count)).lowercased()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw ToolError.checksumMismatch(name) }
    }

    /// Unpacks into a staging folder, then swaps it in so a failed update never breaks the current install.
    @concurrent
    private nonisolated static func unpack(_ file: URL, tool: Tool) async throws {
        let fm = FileManager.default
        let staging = root.appending(path: ".\(tool.rawValue)-staging")
        let final = root.appending(path: tool.rawValue)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        if tool.isZip {
            let result = try await ProcessRunner.run(URL(filePath: "/usr/bin/ditto"),
                                                     arguments: ["-x", "-k", file.path, staging.path],
                                                     timeout: .seconds(120))
            guard result.status == 0 else { throw ProcessError.failed("ditto", result.status, result.stderrText) }
        } else {
            try fm.copyItem(at: file, to: staging.appending(path: tool.executablePath))
        }
        let exe = staging.appending(path: tool.executablePath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let old = root.appending(path: ".\(tool.rawValue)-old")
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: final.path) { try fm.moveItem(at: final, to: old) }
        try fm.moveItem(at: staging, to: final)
        try? fm.removeItem(at: old)
    }

    // MARK: - Manifest

    private nonisolated static var manifestURL: URL { root.appending(path: "manifest.json") }

    private nonisolated static func loadManifest() -> [Tool: InstalledTool] {
        guard let data = try? Data(contentsOf: manifestURL),
              let raw = try? JSONDecoder().decode([String: InstalledTool].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Tool(rawValue: k).map { ($0, v) } })
    }

    private nonisolated static func saveManifest(_ manifest: [Tool: InstalledTool]) {
        let raw = Dictionary(uniqueKeysWithValues: manifest.map { ($0.key.rawValue, $0.value) })
        try? JSONEncoder().encode(raw).write(to: manifestURL, options: .atomic)
    }
}
