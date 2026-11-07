import SwiftUI
import OSLog

/// Sidebar destinations.
enum Destination: String, Hashable, CaseIterable, Identifiable {
    case home, shorts, live, history, watchLater, playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .shorts: "Shorts"
        case .live: "Live"
        case .history: "History"
        case .watchLater: "Watch Later"
        case .playlists: "Playlists"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .shorts: "play.rectangle.on.rectangle"
        case .live: "dot.radiowaves.left.and.right"
        case .history: "clock.arrow.circlepath"
        case .watchLater: "clock"
        case .playlists: "list.bullet.rectangle"
        }
    }
}

/// App-wide state shared through the environment.
@Observable
final class AppModel {
    let client = InnerTubeClient()
    let settings = Preferences()
    let tools = ToolManager()
    @ObservationIgnored private(set) lazy var resolver = StreamResolver(
        tools: tools, preferences: settings,
        session: { [weak self] in await self?.session }
    )

    var destination: Destination?
    var searchText = ""
    /// The submitted query; non-nil shows search results instead of the destination.
    var activeSearch: String?

    init() {
        destination = settings.startPage
        #if DEBUG
        // `-VelvetSearch "query"` opens straight into results; handy for testing.
        if let q = UserDefaults.standard.string(forKey: "VelvetSearch"), !q.isEmpty {
            searchText = q
            activeSearch = q
        }
        #endif
    }

    func submitSearch() {
        closePlayer()
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearch = q.isEmpty ? nil : q
    }

    // MARK: - Playback

    /// The video being watched; non-nil shows the watch page.
    private(set) var watching: PlayerSession?
    var playerFullscreen = false

    func open(_ video: Video, at position: Double = 0) {
        watching?.close()
        let session = PlayerSession(video: video, resolver: resolver, preferences: settings,
                                    client: client, signedIn: authState == .signedIn)
        session.startPosition = position
        watching = session
        session.start()
    }

    func closePlayer() {
        if playerFullscreen { togglePlayerFullscreen() }
        watching?.close()
        watching = nil
    }

    /// True when entering player fullscreen also put the window into macOS fullscreen,
    /// so leaving it should take the window back out (and only then).
    @ObservationIgnored private var playerOwnsWindowFullscreen = false

    func togglePlayerFullscreen() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let windowIsFullscreen = window?.styleMask.contains(.fullScreen) ?? false
        if !playerFullscreen {
            playerFullscreen = true
            playerOwnsWindowFullscreen = !windowIsFullscreen
            if !windowIsFullscreen { window?.toggleFullScreen(nil) }
        } else {
            playerFullscreen = false
            if playerOwnsWindowFullscreen && windowIsFullscreen { window?.toggleFullScreen(nil) }
            playerOwnsWindowFullscreen = false
        }
    }

    /// The window left macOS fullscreen on its own (green button, Esc, Mission Control).
    func windowDidExitFullscreen() {
        if playerOwnsWindowFullscreen { playerFullscreen = false }
        playerOwnsWindowFullscreen = false
    }

    /// Resolves streams ahead of a likely click (hovering a card).
    func prefetch(_ video: Video) {
        guard settings.prefetchOnHover, video.kind != .upcoming else { return }
        Task { await resolver.prefetch(video.id, isLive: video.kind == .live) }
    }

    func navigate(to destination: Destination) {
        closePlayer()
        activeSearch = nil
        self.destination = destination
    }

    // MARK: - Account

    enum AuthState: Equatable {
        case unknown, signedOut, signedIn
    }

    private(set) var authState: AuthState = .unknown
    private(set) var account: Account?
    private(set) var session: YouTubeSession?
    var showingSignIn = false
    /// Bumped on sign-in/out so account-dependent feeds rebuild.
    private(set) var authRevision = 0 {
        didSet { rebuildAccountFeeds() }
    }

    /// Recommendations; kept here so the feed survives navigating away and back.
    private(set) var homeFeed: FeedModel?

    private func rebuildAccountFeeds() {
        homeFeed = authState == .signedIn ? FeedModel(source: .browse("FEwhat_to_watch"), client: client) : nil
    }

    /// Restores a saved session at launch.
    func start() async {
        guard authState == .unknown else { return }
        prepareTools()
        #if DEBUG
        // `-VelvetPlay <videoId>` opens straight into the player; handy for testing.
        if let id = UserDefaults.standard.string(forKey: "VelvetPlay"), !id.isEmpty {
            open(Video(id: id, title: "Debug: \(id)"), at: UserDefaults.standard.double(forKey: "VelvetStart"))
            // `-VelvetResizeTest YES`: pause, then grow the window, to check mpv follows the new size.
            if UserDefaults.standard.bool(forKey: "VelvetResizeTest") {
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    watching?.player.pause()
                    try? await Task.sleep(for: .seconds(1))
                    if let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                        w.setFrame(NSRect(x: 60, y: 60, width: 1500, height: 950), display: true, animate: false)
                    }
                }
            }
        }
        #endif
        if let saved = YouTubeSession.restore() {
            await activate(saved)
        } else {
            authState = .signedOut
        }
    }

    func completeSignIn(cookies: [StoredCookie]) async {
        showingSignIn = false
        let session = YouTubeSession(cookies: cookies)
        await session.save()
        await activate(session)
    }

    func signOut() async {
        await client.setAuth(nil)
        await client.invalidateConfig()
        SessionStore.shared.clear()
        session = nil
        account = nil
        authState = .signedOut
        authRevision += 1
    }

    private func activate(_ session: YouTubeSession) async {
        self.session = session
        await client.setAuth(session)
        await client.invalidateConfig() // signed-in pages carry their own visitor data
        authState = .signedIn
        authRevision += 1
        await refreshAccount()
    }

    func refreshAccount() async {
        do {
            let json = try await client.accountMenu()
            account = Account(accountMenu: json)
            if account == nil {
                // No account header means the cookies no longer authenticate.
                log.warning("Account menu had no active account; session may have expired")
            }
        } catch {
            log.error("Account fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Tools

    /// Installs yt-dlp + the selected runtime in the background so the first video doesn't wait,
    /// then runs the daily update check.
    private func prepareTools() {
        Task(priority: .utility) { [tools, settings] in
            do {
                _ = try await tools.ready(runtime: settings.jsRuntime)
            } catch {
                log.error("Tool setup failed: \(error.localizedDescription, privacy: .public)")
            }
            if settings.autoUpdateTools { await tools.checkForUpdates() }
        }
    }

    private let log = Logger(subsystem: "com.subhash.Velvet", category: "App")
}
