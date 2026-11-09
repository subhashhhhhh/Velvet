import SwiftUI

/// Renders a sectioned feed: per section an optional header, a video grid and a Shorts row.
struct SectionedFeedView: View {
    let feed: SectionedFeedModel
    var emptyMessage = "Nothing here yet."
    /// Set for playlists: clicking a video plays the playlist from there (the rest queued).
    var playlistTitle: String?
    @Environment(AppModel.self) private var app
    @State private var layout = GridLayout()
    @State private var tracker = GridTracker()
    @State private var scroll = ScrollPosition()

    private var columnCount: Int { VideoGrid.columns(layout, prefs: app.settings) }

    var body: some View {
        Group {
            if feed.isEmpty {
                if feed.isLoading || !feed.hasLoaded {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = feed.error {
                    ContentUnavailableView {
                        Label("Couldn't Load", systemImage: "wifi.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { Task { await feed.reload() } }
                    }
                } else {
                    ContentUnavailableView(emptyMessage, systemImage: "tray")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(feed.sections) { section in
                            if let title = section.title {
                                Text(title).font(.title3.weight(.semibold))
                            }
                            if !section.videos.isEmpty { grid(section.videos) }
                            if !section.shorts.isEmpty && app.settings.showShortsShelf {
                                ShortsShelf(shorts: section.shorts, onOpen: { app.open($0) })
                            }
                        }
                        if feed.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
                    }
                    .padding(VideoGrid.padding)
                    .coordinateSpace(.named(GridTracker.space))
                    .gridWidth(layout)
                }
                .trackedGridScroll($scroll, tracker: tracker)
                .sidebarStableLayout($layout) {
                    tracker.keepReadingPosition(order: feed.sections.flatMap(\.videos), scroll: $scroll)
                }
            }
        }
        .task { await feed.loadIfNeeded() }
        .topBarRefresh { await feed.reload() }
    }

    private func grid(_ videos: [Video]) -> some View {
        LazyVGrid(columns: VideoGrid.gridItems(columnCount), alignment: .leading, spacing: 18) {
            ForEach(videos) { video in
                Button {
                    if let playlistTitle {
                        app.play(video, inPlaylist: feed.sections.flatMap(\.videos), title: playlistTitle)
                    } else {
                        app.open(video)
                    }
                } label: { VideoCard(video: video) }
                    .buttonStyle(.plain)
                    .trackedInGrid(video.id, by: tracker)
                    .onAppear {
                        if video.id == feed.sections.last?.videos.last?.id { Task { await feed.loadMore() } }
                    }
            }
        }
    }
}

/// Shown on account-only pages when signed out.
struct SignInRequiredView: View {
    let title: String
    let symbol: String
    let message: String
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button("Sign In with Google") { app.showingSignIn = true }.buttonStyle(.borderedProminent)
        }
    }
}

struct LibraryFeedPage: View {
    let destination: Destination
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.authState {
            case .unknown:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SignInRequiredView(title: destination.title, symbol: destination.symbol,
                                   message: "Sign in to see your \(destination.title.lowercased()).")
            case .signedIn:
                if let feed = app.libraryFeed(for: destination) {
                    SectionedFeedView(feed: feed, emptyMessage: destination == .history ? "No watch history yet." : "No videos saved yet.",
                                      playlistTitle: destination == .watchLater ? "Watch Later" : nil)
                        .id(app.authRevision)
                }
            }
        }
        .navigationTitle(destination.title)
        .topBarTitle(destination.title)
    }
}

// MARK: - Playlists

struct PlaylistsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.authState {
            case .unknown:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SignInRequiredView(title: "Playlists", symbol: "list.bullet.rectangle", message: "Sign in to see your playlists.")
            case .signedIn:
                if let model = app.playlistsModel {
                    if let open = app.openPlaylist {
                        PlaylistDetailView(summary: open)
                            .id(open.id)
                            .topBarBack { app.openPlaylist = nil }
                    } else {
                        PlaylistsGrid(model: model) { app.openPlaylist = $0 }
                            .id(app.authRevision)
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .topBarTitle("Playlists")
    }
}

private struct PlaylistsGrid: View {
    let model: PlaylistsModel
    var onOpen: (PlaylistSummary) -> Void

    var body: some View {
        Group {
            if model.playlists.isEmpty {
                if model.isLoading || !model.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.error {
                    ContentUnavailableView("Couldn't Load Playlists", systemImage: "wifi.exclamationmark", description: Text(error))
                } else {
                    ContentUnavailableView("No Playlists", systemImage: "list.bullet.rectangle")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 16, alignment: .top)], spacing: 20) {
                        ForEach(model.playlists) { p in
                            Button { onOpen(p) } label: { PlaylistCard(playlist: p) }.buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task { await model.loadIfNeeded() }
        .topBarRefresh { await model.reload() }
    }
}

struct PlaylistCard: View {
    let playlist: PlaylistSummary
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                // A stacked edge hints that this is a collection, not a single video.
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary)
                    .padding(.horizontal, 10).offset(y: -6)
                RemoteImage(url: playlist.thumbnail)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if let count = playlist.countText {
                            Label(count, systemImage: "list.bullet").labelStyle(.titleAndIcon)
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                        }
                    }
            }
            .padding(.top, 6)
            Text(playlist.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            if let sub = playlist.subtitle, !sub.isEmpty {
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct PlaylistDetailView: View {
    let summary: PlaylistSummary
    @Environment(AppModel.self) private var app
    @State private var feed: SectionedFeedModel?

    var body: some View {
        Group {
            if let feed {
                SectionedFeedView(feed: feed, emptyMessage: "This playlist is empty.", playlistTitle: feed.title ?? summary.title)
            } else {
                // Not empty: an empty view takes no space and never runs its .task.
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(feed?.title ?? summary.title)
        .topBarTitle(feed?.title ?? summary.title)
        .task { if feed == nil { feed = SectionedFeedModel(browseId: summary.browseId, client: app.client) } }
    }
}
