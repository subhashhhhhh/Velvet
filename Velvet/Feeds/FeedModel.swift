import Foundation
import OSLog

/// A paginated list of videos from any InnerTube surface (home, search, …).
@Observable
final class FeedModel {
    enum Source: Hashable, Sendable {
        case browse(String, params: String? = nil)
        case search(String)
    }

    let source: Source
    private(set) var videos: [Video] = []
    private(set) var shorts: [Video] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var hasLoaded = false
    var canLoadMore: Bool { continuation != nil }

    private var continuation: String?
    private var seen = Set<String>()
    private let client: InnerTubeClient
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Feed")

    init(source: Source, client: InnerTubeClient) {
        self.source = source
        self.client = client
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        videos = []; shorts = []; seen = []; continuation = nil
        await load(continuation: nil)
        hasLoaded = true
    }

    func loadMore() async {
        guard let token = continuation, !isLoading else { return }
        await load(continuation: token)
    }

    private func load(continuation token: String?) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await Self.fetch(source, continuation: token, client: client)
            for v in page.videos where seen.insert(v.id).inserted {
                if v.kind == .short { shorts.append(v) } else { videos.append(v) }
            }
            continuation = page.continuation
        } catch {
            log.error("Feed load failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private struct Page: Sendable {
        let videos: [Video]
        let continuation: String?
    }

    /// Network + parsing, off the main actor.
    @concurrent
    private static func fetch(_ source: Source, continuation token: String?, client: InnerTubeClient) async throws -> Page {
        let json: JSON
        switch (source, token) {
        case (.browse(let id, let params), nil): json = try await client.browse(id, params: params)
        case (.browse, let token?): json = try await client.browse(continuation: token)
        case (.search(let q), nil): json = try await client.search(q)
        case (.search, let token?): json = try await client.search(continuation: token)
        }
        // The feed's own "load more" token sits after its items, so take the last one.
        return Page(videos: VideoParser.videos(in: json), continuation: VideoParser.continuations(in: json).last)
    }
}
