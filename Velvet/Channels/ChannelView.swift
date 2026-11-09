import SwiftUI

struct ChannelView: View {
    let model: ChannelModel
    @Environment(AppModel.self) private var app
    @State private var layout = GridLayout()
    /// One of the channel's playlists, shown over the channel (which keeps its place).
    @State private var openPlaylist: PlaylistSummary?

    var body: some View {
        ZStack {
            content
                .opacity(openPlaylist == nil ? 1 : 0)
                .allowsHitTesting(openPlaylist == nil)
            if let openPlaylist {
                PlaylistDetailView(summary: openPlaylist)
                    .id(openPlaylist.id)
                    .topBarBack { self.openPlaylist = nil }
            }
        }
        .navigationTitle(model.header?.name ?? "Channel")
        .task { await model.load() }
        .alert("Couldn't Complete That", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: { Text(model.actionError ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        if let header = model.header {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ChannelHeaderView(header: header, model: model)
                    if !header.tabs.isEmpty {
                        tabBar(header.tabs)
                    }
                    if let results = model.searchResults {
                        ChannelTabGrid(content: results, columns: VideoGrid.columns(layout, prefs: app.settings)) { openPlaylist = $0 }
                            .id("search \(results.query ?? "")")
                    } else if let tab = model.currentTab {
                        ChannelTabGrid(content: tab, columns: VideoGrid.columns(layout, prefs: app.settings)) { openPlaylist = $0 }.id(tab.tab.id)
                    }
                }
                .padding(VideoGrid.padding)
                .gridWidth(layout)
            }
            .sidebarStableLayout($layout)
        } else if let error = model.error {
            ContentUnavailableView {
                Label("Couldn't Load Channel", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: { Text(error) }
        } else {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tabBar(_ tabs: [ChannelTab]) -> some View {
        HStack {
            // The home feed's chips, for the same look.
            HStack(spacing: 8) {
                ForEach(tabs) { tab in
                    Chip(title: tab.title, isOn: model.searchResults == nil && model.selectedTab == tab.kind) {
                        model.clearSearch()
                        model.selectedTab = tab.kind
                    }
                }
            }
            Spacer()
            playAllButton
            ChannelSearchField(model: model)
            if model.searchResults == nil, let tab = model.currentTab, !tab.chips.isEmpty {
                Menu {
                    ForEach(tab.chips) { chip in
                        Button { Task { await tab.select(chip) } } label: {
                            if chip.selected { Label(chip.title, systemImage: "checkmark") } else { Text(chip.title) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                        Text(tab.selectedChip?.title ?? "Sort")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

private struct ChannelHeaderView: View {
    let header: ChannelHeader
    let model: ChannelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let banner = header.banner {
                RemoteImage(url: banner)
                    .aspectRatio(6.2, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(alignment: .center, spacing: 16) {
                RemoteImage(url: header.avatar)
                    .frame(width: 88, height: 88)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(header.name).font(.largeTitle.weight(.bold)).lineLimit(1)
                    Text([header.handle, header.subscribers, header.videoCount].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    if let d = header.description, !d.isEmpty {
                        Text(d).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                }
                Spacer()
                subscribeButton
            }
        }
    }

    private var subscribeButton: some View {
        SubscribeButton(channelName: header.name, isSubscribed: model.isSubscribed, bell: model.bell,
                        onSubscribe: { model.setSubscribed(true) },
                        onUnsubscribe: { model.setSubscribed(false) },
                        onBell: { model.setBell($0) })
            .controlSize(.large)
    }
}

private struct ChannelTabGrid: View {
    let content: ChannelTabContent
    /// Video columns, per the "videos per row" settings.
    let columns: Int
    var onOpenPlaylist: (PlaylistSummary) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if content.isEmpty {
                if content.isLoading || !content.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if let error = content.error {
                    ContentUnavailableView("Couldn't Load", systemImage: "wifi.exclamationmark", description: Text(error))
                } else {
                    ContentUnavailableView("Nothing Here", systemImage: "tray")
                }
            } else {
                switch content.tab.kind {
                case .shorts:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12, alignment: .top)], spacing: 16) {
                        ForEach(content.shorts) { s in
                            Button { app.open(s) } label: { ShortCard(video: s) }.buttonStyle(.plain)
                                .onAppear { if s.id == content.shorts.last?.id { Task { await content.loadMore() } } }
                        }
                    }
                case .playlists:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 16, alignment: .top)], spacing: 20) {
                        ForEach(content.playlists) { p in
                            Button { onOpenPlaylist(p) } label: { PlaylistCard(playlist: p) }.buttonStyle(.plain)
                                .onAppear { if p.id == content.playlists.last?.id { Task { await content.loadMore() } } }
                        }
                    }
                case .videos, .live:
                    LazyVGrid(columns: VideoGrid.gridItems(columns), alignment: .leading, spacing: 18) {
                        ForEach(content.videos) { v in
                            Button { app.open(v) } label: { VideoCard(video: v) }.buttonStyle(.plain)
                                .onAppear { if v.id == content.videos.last?.id { Task { await content.loadMore() } } }
                        }
                    }
                }
                if content.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
        }
        .task { await content.loadIfNeeded() }
    }
}

extension ChannelView {
    /// Plays the videos shown (the tab in its sort order, or the search results) through the
    /// queue, like a playlist.
    @ViewBuilder
    fileprivate var playAllButton: some View {
        let content = model.searchResults ?? model.currentTab
        if let content, !content.videos.isEmpty, content.tab.kind != .shorts {
            Button {
                let name = model.header?.name ?? "Channel"
                let title = content.query.map { "\(name): “\($0)”" } ?? name
                app.play(content.videos[0], inPlaylist: content.videos, title: title)
            } label: {
                Label("Play All", systemImage: "play.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.primary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play these videos in order, with the rest in the queue")
        }
    }
}

/// Searches the channel's videos (YouTube's channel search). Esc or ✕ goes back to the tabs.
private struct ChannelSearchField: View {
    let model: ChannelModel
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search channel", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { model.search(text) }
                .onExitCommand { text = ""; model.clearSearch() }
            if !text.isEmpty || model.searchResults != nil {
                Button { text = ""; model.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Back to the channel's videos")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 200, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.1)))
        // A chip that's already been cleared by a tab chip empties the field too.
        .onChange(of: model.searchResults == nil) { _, cleared in if cleared { text = "" } }
    }
}
