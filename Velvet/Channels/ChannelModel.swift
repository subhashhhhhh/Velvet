import Foundation
import OSLog

/// One channel tab's items, sort chips and pagination.
@Observable
final class ChannelTabContent {
    let tab: ChannelTab
    private(set) var videos: [Video] = []
    private(set) var shorts: [Video] = []
    private(set) var playlists: [PlaylistSummary] = []
    private(set) var chips: [SortChip] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?

    var isEmpty: Bool { videos.isEmpty && shorts.isEmpty && playlists.isEmpty }
    var selectedChip: SortChip? { chips.first(where: \.selected) }

    @ObservationIgnored private var continuation: String?
    /// Set for a search inside the channel (its videos matching these words).
    let query: String?
    @ObservationIgnored private let channelId: String
    @ObservationIgnored private let client: InnerTubeClient
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "Channel")

    /// The channel page's search tab, as youtube.com requests it.
    static let searchParams = "EgZzZWFyY2jyBgQKAloA"

    init(tab: ChannelTab, channelId: String, client: InnerTubeClient, query: String? = nil) {
        self.tab = tab
        self.query = query
        self.channelId = channelId
        self.client = client
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await Task { await self.load(.first) }.value
    }

    func loadMore() async {
        guard let token = continuation, !isLoading else { return }
        await load(.more(token))
    }

    /// Re-sorts: the chip's token returns the tab's items in that order.
    func select(_ chip: SortChip) async {
        guard !chip.selected, !isLoading else { return }
        chips = chips.map { SortChip(title: $0.title, token: $0.token, selected: $0.title == chip.title) }
        await load(.sort(chip.token))
    }

    private enum Request { case first, more(String), sort(String) }

    private func load(_ request: Request) async {
        isLoading = true
        error = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            let json: JSON
            switch request {
            case .first:
                json = try await client.browse(channelId, params: query == nil ? tab.params : Self.searchParams, query: query)
            case .more(let t), .sort(let t): json = try await client.browse(continuation: t)
            }
            if case .more = request {} else { videos = []; shorts = []; playlists = [] }
            if case .first = request { chips = ChannelParser.sortChips(in: json) }

            let found = VideoParser.videos(in: json)
            let known = Set(videos.map(\.id) + shorts.map(\.id))
            videos += found.filter { $0.kind != .short && !known.contains($0.id) }
            shorts += found.filter { $0.kind == .short && !known.contains($0.id) }
            let knownPlaylists = Set(playlists.map(\.id))
            playlists += LibraryParser.playlists(in: json).filter { !knownPlaylists.contains($0.id) }
            continuation = VideoParser.continuations(in: json).last
            MemoryRelief.soon()
        } catch {
            log.error("Channel tab \(self.tab.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }
}

/// A channel page: header, subscription, and its tabs.
@Observable
final class ChannelModel: Identifiable {
    let id: String
    private(set) var header: ChannelHeader?
    private(set) var error: String?
    private(set) var isSubscribed = false
    private(set) var bell: ChannelBell?
    private(set) var actionError: String?
    var selectedTab: ChannelTab.Kind = .videos
    private(set) var tabs: [ChannelTab.Kind: ChannelTabContent] = [:]

    @ObservationIgnored private let client: InnerTubeClient
    @ObservationIgnored private let isSignedIn: () -> Bool

    init(channelId: String, client: InnerTubeClient, isSignedIn: @escaping () -> Bool) {
        self.id = channelId
        self.client = client
        self.isSignedIn = isSignedIn
    }

    var currentTab: ChannelTabContent? { tabs[selectedTab] }

    /// A search inside the channel, shown instead of the selected tab.
    private(set) var searchResults: ChannelTabContent?

    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clearSearch(); return }
        guard q != searchResults?.query else { return }
        searchResults = ChannelTabContent(tab: ChannelTab(kind: .videos, title: "Search", params: ""),
                                          channelId: id, client: client, query: q)
    }

    func clearSearch() { searchResults = nil }

    func load() async {
        guard header == nil else { return }
        do {
            let json = try await client.browse(id)
            guard let h = ChannelParser.header(from: json, channelId: id) else {
                error = "Couldn't read this channel."
                return
            }
            header = h
            isSubscribed = h.isSubscribed
            bell = h.bell
            for tab in h.tabs { tabs[tab.kind] = ChannelTabContent(tab: tab, channelId: id, client: client) }
            if tabs[selectedTab] == nil, let first = h.tabs.first { selectedTab = first.kind }
            MemoryRelief.soon()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setSubscribed(_ subscribed: Bool) {
        guard isSignedIn() else { actionError = "Sign in to subscribe."; return }
        let previous = (isSubscribed, bell)
        isSubscribed = subscribed
        bell = subscribed ? ChannelBell.afterSubscribing(to: id) : nil
        Task {
            do {
                if subscribed { try await client.subscribe(to: id) } else { try await client.unsubscribe(from: id) }
            } catch {
                (isSubscribed, bell) = previous
                actionError = "Couldn't update your subscription: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Notification bell

    func setBell(_ setting: BellSetting) {
        guard let current = bell, let params = current.params[setting], current.setting != setting else { return }
        bell?.setting = setting
        Task {
            do {
                try await client.setChannelNotifications(params: params)
            } catch {
                bell?.setting = current.setting
                actionError = "Couldn't change notifications: \(error.localizedDescription)"
            }
        }
    }

    func dismissError() { actionError = nil }
}
