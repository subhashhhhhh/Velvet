import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var sidebarVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: Binding(
            get: { app.playerFullscreen ? .detailOnly : sidebarVisibility },
            set: { if !app.playerFullscreen { sidebarVisibility = $0 } }
        )) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            detail
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search YouTube")
        .onSubmit(of: .search) { app.submitSearch() }
        .sheet(isPresented: $app.showingSignIn) {
            SignInView(
                onComplete: { cookies in Task { await app.completeSignIn(cookies: cookies) } },
                onCancel: { app.showingSignIn = false }
            )
        }
        .task { await app.start() }
        .background(WindowReader { app.mainWindow = $0 })
    }

    @ViewBuilder
    private var detail: some View {
        if let session = app.watching {
            WatchView(session: session).id(session.id)
        } else if let shorts = app.shortsOverlay {
            ShortsPlayerView(controller: shorts, showsBack: true).id(ObjectIdentifier(shorts))
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
        .task(id: query) { feed = FeedModel(source: .search(query), client: app.client) }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List(selection: Binding(
            get: { app.activeSearch == nil ? app.destination : nil },
            set: { if let d = $0 { app.navigate(to: d) } }
        )) {
            Section {
                ForEach([Destination.home, .shorts, .live]) { row($0) }
            }
            Section("Library") {
                ForEach([Destination.history, .watchLater, .playlists]) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { AccountFooter().padding(10) }
    }

    private func row(_ d: Destination) -> some View {
        Label(d.title, systemImage: d.symbol).tag(d)
    }
}

struct AccountFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.authState {
        case .unknown:
            EmptyView()
        case .signedOut:
            Button {
                app.showingSignIn = true
            } label: {
                Label("Sign In", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
        case .signedIn:
            Menu {
                if let handle = app.account?.handle { Text(handle) }
                Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
            } label: {
                HStack(spacing: 8) {
                    RemoteImage(url: app.account?.photo)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                    Text(app.account?.name ?? "Signed In")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
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
