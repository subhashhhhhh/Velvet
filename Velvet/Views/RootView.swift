import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 0) {
            Sidebar()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, TopBar.height)
                .withTopBar()
        }
        // Velvet draws its own top bar where the title bar is; the (empty) system toolbar
        // stays only so the window buttons sit in the middle of that bar.
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .overlay(alignment: .topLeading) { PlayerLayer() }
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) }
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(app.playerFullscreen ? .hidden : .visible, for: .windowToolbar)
        // In fullscreen the toolbar (and its window buttons) comes down with the menu bar
        // only when the pointer is at the top of the screen; otherwise macOS keeps it as an
        // opaque band over the top bar.
        .windowToolbarFullScreenVisibility(.onHover)
        .sheet(isPresented: $app.showingSignIn) {
            SignInView(
                onComplete: { cookies in Task { await app.completeSignIn(cookies: cookies) } },
                onCancel: { app.showingSignIn = false }
            )
        }
        .sheet(item: $app.playlistPickerVideo) { PlaylistPicker(video: $0) }
        .alert("Couldn't Complete That", isPresented: Binding(get: { app.actionError != nil }, set: { if !$0 { app.actionError = nil } })) {
            Button("OK") { app.actionError = nil }
        } message: {
            Text(app.actionError ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 2)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.toast)
        .task { await app.start() }
        .background(WindowReader { app.mainWindow = $0 })
    }

    @ViewBuilder
    private var detail: some View {
        if let session = app.watching, !app.watchPageHidden {
            WatchView(session: session).id(session.id)
        } else if let shorts = app.shortsOverlay {
            ShortsPlayerView(controller: shorts, showsBack: true).id(ObjectIdentifier(shorts))
        } else if let channel = app.channel {
            ChannelView(model: channel).id(channel.id)
        } else if let query = app.activeSearch {
            SearchResultsView(query: query)
        } else {
            switch app.destination ?? .home {
            case .home:
                HomeView()
            case .history, .watchLater:
                LibraryFeedPage(destination: app.destination ?? .home).id(app.destination)
            case .playlists:
                PlaylistsPage()
            case .queue:
                QueueView()
            case .live:
                SectionedFeedView(feed: app.liveFeed, emptyMessage: "Nothing is live right now.")
                    .navigationTitle("Live")
                    .topBarTitle("Live")
            case .shorts:
                if let shorts = app.shortsTab {
                    // Identity follows the controller so a rebuilt one gets its own start.
                    ShortsPlayerView(controller: shorts, showsBack: false).id(ObjectIdentifier(shorts))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case let d:
                PlaceholderView(title: d.title, symbol: d.symbol, message: "Coming soon.")
            }
        }
    }
}

struct SearchResultsView: View {
    let query: String
    @Environment(AppModel.self) private var app
    @State private var feed: FeedModel?

    var body: some View {
        Group {
            if let feed, feed.source == .search(query) {
                FeedView(feed: feed, onOpen: { app.open($0) }).id(query)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(query)
        .topBarBack {
            app.activeSearch = nil
            app.searchText = ""
        }
        .task(id: query) {
            let f = FeedModel(source: .search(query), client: app.client)
            f.hidesPromotions = { [settings = app.settings] in settings.hidePromotions }
            feed = f
        }
    }
}

struct PlaceholderView: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .navigationTitle(title)
    }
}

/// Reports the hosting NSWindow (for window-level behaviour like automatic PiP).
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}

/// Draws the watch-page player above the whole window: over its slot in the page normally,
/// or over everything in fullscreen. One view, one animated frame — no sidebar/column changes.
struct PlayerLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            if let session = app.watching, !app.watchPageHidden {
                let origin = geo.frame(in: .global).origin
                let full = app.playerFullscreen
                let bounds = CGRect(origin: .zero, size: geo.size)
                let slot = app.playerSlot.offsetBy(dx: -origin.x, dy: -origin.y)
                let frame = full ? bounds : slot
                // Inline, keep the player inside the page's visible area (it scrolls with the page).
                let clip = full ? bounds : app.watchViewport.offsetBy(dx: -origin.x, dy: -origin.y)

                // SwiftUI can't mask native views (mpv's Metal surface renders black under .mask),
                // so clip with a plain rectangle: a container the size of the visible part.
                let visible = frame.intersection(clip)
                ZStack(alignment: .topLeading) {
                    PlayerView(session: session, isFullscreen: full) { app.togglePlayerFullscreen() }
                        .frame(width: max(0, frame.width), height: max(0, frame.height))
                        .clipShape(RoundedRectangle(cornerRadius: full || app.settings.theaterMode ? 0 : 12, style: .continuous))
                        .offset(x: frame.minX - (visible.isNull ? 0 : visible.minX),
                                y: frame.minY - (visible.isNull ? 0 : visible.minY))
                }
                .frame(width: visible.isNull ? 0 : visible.width, height: visible.isNull ? 0 : visible.height, alignment: .topLeading)
                .clipped()
                .offset(x: visible.isNull ? 0 : visible.minX, y: visible.isNull ? 0 : visible.minY)
                .opacity(app.playerSlot == .zero && !full ? 0 : 1)
                .id(session.id)
            }
        }
        .ignoresSafeArea()
    }
}
