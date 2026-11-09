// Finds the newest release. It reads updates/latest.json from the repository through
// raw.githubusercontent.com first: GitHub's API allows only 60 requests an hour per IP address
// without an account, which a shared network uses up for everyone. The API is the fallback.
// scripts/release.sh writes the manifest when it publishes a release.

import Foundation
import OSLog

/// A published release this Mac can install.
nonisolated struct AvailableRelease: Sendable, Equatable {
    let version: AppVersion
    let tag: String
    /// The changelog, without the download and install instructions.
    let notes: String
    let pageURL: URL
    let archiveURL: URL
    let archiveSize: Int64
    /// SHA-256 of the zip, lowercase hex, when known.
    let archiveSHA256: String?
}

nonisolated enum ReleaseFeed {
    static let repository = "subhashhhhhh/Velvet"
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    static let newIssue = URL(string: "https://github.com/\(repository)/issues/new")!

    /// Release notes end the in-app changelog at this marker; what follows is for people
    /// downloading by hand.
    static let installMarker = "<!-- velvet:install -->"

    /// The build for this Mac's processor. An Intel build stays on Intel builds even when it
    /// runs under Rosetta.
    static var architectureLabel: String {
        #if arch(x86_64)
        "Intel"
        #else
        "AppleSilicon"
        #endif
    }

    private static let log = Logger(subsystem: "com.subhash.Velvet", category: "Updates")

    /// `VELVET_UPDATE_FEED` points the updater at a test feed (GitHub's release JSON). Whatever
    /// it serves still has to pass the signature check before it is installed.
    private static var testFeed: URL? {
        ProcessInfo.processInfo.environment["VELVET_UPDATE_FEED"].flatMap(URL.init(string:))
    }

    private static let manifestURL = URL(string: "https://raw.githubusercontent.com/\(repository)/main/updates/latest.json")!
    private static let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    enum FeedError: LocalizedError {
        case badResponse(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .badResponse(403), .badResponse(429): "GitHub is limiting requests from this network. Try again later."
            case .badResponse(404): "No release has been published yet."
            case .badResponse(let status): "GitHub answered with status \(status)."
            case .unreadable: "The release information couldn't be read."
            }
        }
    }

    /// The latest release, or nil when it has no zip for this Mac.
    @concurrent static func latest() async throws -> AvailableRelease? {
        if testFeed == nil {
            do {
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: try await fetch(manifestURL))
                return available(from: manifest)
            } catch {
                log.info("Manifest unavailable (\(error.localizedDescription, privacy: .public)); asking GitHub's API")
            }
        }
        let data = try await fetch(testFeed ?? apiURL, api: true)
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else { throw FeedError.unreadable }
        return available(from: release)
    }

    private static func fetch(_ url: URL, api: Bool = false) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        if api { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        // GitHub refuses requests without a User-Agent.
        request.setValue("Velvet/\(AppVersion.current?.description ?? "0")", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FeedError.badResponse(status) }
        return data
    }

    static func available(from manifest: UpdateManifest) -> AvailableRelease? {
        guard let version = AppVersion(manifest.version),
              let archive = manifest.archives[architectureLabel],
              let url = URL(string: "https://github.com/\(repository)/releases/download/\(manifest.tag)/\(archive.name)"),
              let page = URL(string: "https://github.com/\(repository)/releases/tag/\(manifest.tag)") else { return nil }
        return AvailableRelease(version: version, tag: manifest.tag, notes: manifest.notes, pageURL: page,
                                archiveURL: url, archiveSize: archive.size, archiveSHA256: archive.sha256.lowercased())
    }

    static func available(from release: GitHubRelease) -> AvailableRelease? {
        guard !release.draft, !release.prerelease, let version = AppVersion(release.tag_name) else { return nil }
        let archiveName = "Velvet-\(version.description)-\(architectureLabel).zip"
        guard let asset = release.assets.first(where: { $0.name == archiveName }) else { return nil }
        var sha256: String?
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            sha256 = String(digest.dropFirst("sha256:".count)).lowercased()
        }
        return AvailableRelease(version: version, tag: release.tag_name, notes: changelog(from: release.body ?? ""),
                                pageURL: release.html_url, archiveURL: asset.browser_download_url,
                                archiveSize: asset.size, archiveSHA256: sha256)
    }

    static func changelog(from body: String) -> String {
        let text = body.range(of: installMarker).map { String(body[..<$0.lowerBound]) } ?? body
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The parts of GitHub's release JSON the updater reads.
nonisolated struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int64
        let browser_download_url: URL
        let digest: String?
    }

    let tag_name: String
    let body: String?
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
}

/// updates/latest.json in the repository, written by scripts/release.sh.
nonisolated struct UpdateManifest: Decodable, Sendable {
    struct Archive: Decodable, Sendable {
        let name: String
        let size: Int64
        let sha256: String
    }

    let version: String
    let tag: String
    let notes: String
    /// Keyed by architecture label ("AppleSilicon").
    let archives: [String: Archive]
}
