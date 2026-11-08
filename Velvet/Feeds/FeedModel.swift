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
    /// Topic chips above the home feed ("All", "Music", "Formula 1", …). Empty elsewhere.
    private(set) var chips: [FeedChip] = []
    private(set) var selectedChip: FeedChip?

    private var continuation: String?
    private var seen = Set<String>()
    private let client: InnerTubeClient
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Feed")

    init(source: Source, client: InnerTubeClient) {
        self.source = source
        self.client = client
    }

    /// Starts the first load in its own task: a view's `.task` being cancelled (SwiftUI
    /// re-creating the view) must not cancel the load or leave the model marked as loaded.
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await Task { await self.reload() }.value
        #if DEBUG
        // `-VelvetChip N`: select the Nth topic chip after the first load.
        let n = UserDefaults.standard.integer(forKey: "VelvetChip")
        if n > 0, n < chips.count {
            log.info("Test: selecting chip \(self.chips[n].title, privacy: .public)")
            await select(chips[n])
            log.info("Test: chip feed has \(self.videos.count) videos")
        }
        #endif
    }

    func reload() async {
        guard !isLoading else { return }
        videos = []; shorts = []; seen = []; continuation = nil
        if let token = selectedChip?.token {
            await load(continuation: token)
        } else {
            await load(continuation: nil)
        }
        hasLoaded = true
    }

    /// Shows one topic (nil = "All"). The chip's token loads that topic's feed in place.
    func select(_ chip: FeedChip?) async {
        let chip = chip?.token == nil ? nil : chip
        guard chip != selectedChip else { return }
        selectedChip = chip
        chipTask?.cancel()
        chipTask = Task {
            while isLoading { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled, selectedChip == chip else { return }
            await reload()
        }
        await chipTask?.value
    }
    @ObservationIgnored private var chipTask: Task<Void, Never>?

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
            if token == nil, !page.chips.isEmpty { chips = page.chips }
            for v in page.videos where seen.insert(v.id).inserted {
                if v.kind == .short { shorts.append(v) } else { videos.append(v) }
            }
            continuation = page.continuation
            MemoryRelief.soon()
        } catch {
            log.error("Feed load failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private struct Page: Sendable {
        let videos: [Video]
        let continuation: String?
        var chips: [FeedChip] = []
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
        return Page(videos: VideoParser.videos(in: json), continuation: VideoParser.continuations(in: json).last,
                    chips: token == nil ? FeedChip.chips(in: json) : [])
    }
}

nonisolated struct FeedChip: Hashable, Sendable, Identifiable {
    var id: String { title }
    let title: String
    /// Continuation that loads this topic's feed; nil for "All".
    let token: String?

    static func chips(in json: JSON) -> [FeedChip] {
        guard let bar = json.first("feedFilterChipBarRenderer") else { return [] }
        return bar.all("chipCloudChipRenderer").compactMap { c in
            guard let title = c["text"].text, !title.isEmpty else { return nil }
            return FeedChip(title: title, token: c["navigationEndpoint"].first("token")?.string)
        }
    }
}
