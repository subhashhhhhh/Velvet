import Foundation
import OSLog

/// A paginated browse surface whose items arrive in titled sections (History by day,
/// Watch Later and playlists as one untitled section).
@Observable
final class SectionedFeedModel {
    let browseId: String
    private(set) var title: String?
    private(set) var sections: [FeedSection] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    var canLoadMore: Bool { continuation != nil }
    var isEmpty: Bool { sections.allSatisfy { $0.videos.isEmpty && $0.shorts.isEmpty } }

    @ObservationIgnored private var continuation: String?
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private let client: InnerTubeClient
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "Library")

    init(browseId: String, client: InnerTubeClient) {
        self.browseId = browseId
        self.client = client
    }

    /// Starts the first load in its own task: a view's `.task` being cancelled (SwiftUI
    /// re-creating the view) must not cancel the load or leave the model marked as loaded.
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await Task { await self.reload() }.value
    }

    func reload() async {
        guard !isLoading else { return }
        sections = []; seen = []; continuation = nil
        await load(token: nil)
        hasLoaded = true
    }

    func loadMore() async {
        guard let token = continuation, !isLoading else { return }
        await load(token: token)
    }

    private func load(token: String?) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await Self.fetch(browseId: browseId, token: token, client: client)
            if token == nil, let t = page.title { title = t }
            for var section in page.sections {
                section.videos.removeAll { !seen.insert($0.id).inserted }
                section.shorts.removeAll { !seen.insert($0.id).inserted }
                // A day split across pages continues the previous section.
                if let last = sections.indices.last, sections[last].title == section.title {
                    sections[last].videos += section.videos
                    sections[last].shorts += section.shorts
                } else {
                    sections.append(section)
                }
            }
            continuation = page.continuation
            MemoryRelief.soon()
        } catch {
            log.error("Load \(self.browseId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private struct Page: Sendable {
        let title: String?
        let sections: [FeedSection]
        let continuation: String?
    }

    @concurrent
    private static func fetch(browseId: String, token: String?, client: InnerTubeClient) async throws -> Page {
        let json = token == nil ? try await client.browse(browseId) : try await client.browse(continuation: token!)
        return Page(title: LibraryParser.playlistTitle(in: json),
                    sections: LibraryParser.sections(in: json),
                    continuation: VideoParser.continuations(in: json).last)
    }
}

/// Your playlists (Playlists page).
@Observable
final class PlaylistsModel {
    private(set) var playlists: [PlaylistSummary] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?

    @ObservationIgnored private let client: InnerTubeClient

    init(client: InnerTubeClient) { self.client = client }

    /// Starts the first load in its own task: a view's `.task` being cancelled (SwiftUI
    /// re-creating the view) must not cancel the load or leave the model marked as loaded.
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await Task { await self.reload() }.value
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            var json = try await client.browse("FEplaylist_aggregation")
            var all = LibraryParser.playlists(in: json)
            // Follow continuations so large libraries are complete.
            while let token = VideoParser.continuations(in: json).last, all.count < 1000 {
                json = try await client.browse(continuation: token)
                let more = LibraryParser.playlists(in: json).filter { p in !all.contains { $0.id == p.id } }
                if more.isEmpty { break }
                all += more
            }
            playlists = all
        } catch {
            self.error = error.localizedDescription
        }
    }
}
