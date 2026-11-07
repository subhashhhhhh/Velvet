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
    let progress = WatchProgressStore()
    let deArrow = DeArrowService()

    /// DeArrow branding for `video` per current settings (nil when off or nothing better exists).
    func branding(for video: Video) async -> DeArrowBranding? {
        guard settings.deArrowEnabled, video.kind == .video || video.kind == .upcoming else { return nil }
        var b = await deArrow.branding(for: video.id, duration: video.durationSeconds, thumbnails: settings.deArrowThumbnails)
        if !settings.deArrowTitles { b?.title = nil }
        return b
    }
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
        channel = nil
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearch = q.isEmpty ? nil : q
    }

    // MARK: - Playback

    /// The video being watched; non-nil shows the watch page.
    private(set) var watching: PlayerSession?
    var playerFullscreen = false
    /// Where the watch page lays out the player, and the page's visible area (root coordinates).
    /// The player itself is drawn in a window-level layer (RootView) so fullscreen is a single
    /// frame animation over everything, sidebar included.
    var sidebarVisibility = NavigationSplitViewVisibility.automatic
    var playerSlot: CGRect = .zero { didSet { playerVisibilityChanged() } }
    var watchViewport: CGRect = .zero { didSet { playerVisibilityChanged() } }

    /// How much of the inline player is inside the watch page's visible area (0…1).
    var playerVisibleFraction: CGFloat {
        guard playerSlot.height > 0, !watchViewport.isEmpty else { return 1 }
        let visible = playerSlot.intersection(watchViewport)
        return visible.isNull ? 0 : visible.height / playerSlot.height
    }

    func makeSession(for video: Video) -> PlayerSession {
        PlayerSession(video: video, resolver: resolver, preferences: settings,
                      client: client, session: authState == .signedIn ? session : nil,
                      progress: progress,
                      isSignedIn: { [weak self] in self?.authState == .signedIn })
    }

    /// Opens a video. Shorts open in the vertical Shorts player; other videos resume where you left off.
    func open(_ video: Video, at position: Double? = nil) {
        if video.kind == .short && position == nil {
            openShorts(startingWith: video)
            return
        }
        if pip.isActive { exitPictureInPicture() }
        watching?.close()
        shortsOverlay?.close(); shortsOverlay = nil
        let session = makeSession(for: video)
        if let position {
            session.startPosition = position
        } else if video.kind != .live, let resume = progress.resumePosition(for: video) {
            session.startPosition = resume
            session.resumedFrom = resume
        }
        watching = session
        session.start()
    }

    func closePlayer() {
        if pip.isActive { exitPictureInPicture() }
        if playerFullscreen { togglePlayerFullscreen() }
        watching?.close()
        watching = nil
        shortsOverlay?.close()
        shortsOverlay = nil
    }

    // MARK: - Picture in Picture

    @ObservationIgnored let pip = PictureInPicture()
    /// The main window, reported by RootView; watched for visibility to drive automatic PiP.
    @ObservationIgnored weak var mainWindow: NSWindow? {
        didSet { if mainWindow !== oldValue { observeWindow() } }
    }
    @ObservationIgnored private var occlusionObserver: NSObjectProtocol?
    @ObservationIgnored private weak var pipPlayer: MPVPlayer?

    /// The player currently on screen (watch page, a Short), if any.
    var activePlayer: MPVPlayer? {
        if let watching { return watching.player }
        if let shortsOverlay { return shortsOverlay.session?.player }
        if destination == .shorts, activeSearch == nil { return shortsTab?.session?.player }
        return nil
    }

    func togglePictureInPicture() {
        pip.isActive ? exitPictureInPicture() : enterPictureInPicture(automatic: false)
    }

    /// Why PiP started, which decides what ends it.
    enum PiPReason { case manual, windowHidden, scrolledPast }
    @ObservationIgnored private var pipReason: PiPReason = .manual

    func enterPictureInPicture(automatic: Bool, reason: PiPReason? = nil) {
        pipReason = reason ?? (automatic ? .windowHidden : .manual)
        guard PictureInPicture.isAvailable, !pip.isActive, let player = activePlayer else { return }
        // Stay in player fullscreen: coming back should return the video right where it was.
        let returnView = player.inlineView
        let rect = returnView.map { $0.convert($0.bounds, to: nil) }
        let view = player.makePictureInPictureView()
        // Start PiP from where the video is on the page (not the screen's corner): put the PiP
        // view exactly over the inline player first; PiP animates from a view's current frame.
        if let returnView, let content = returnView.window?.contentView {
            view.frame = returnView.convert(returnView.bounds, to: content)
            content.addSubview(view)
        }
        pipPlayer = player
        pip.onPlay = { [weak player] in player?.play() }
        pip.onPause = { [weak player] in player?.pause() }
        pip.onClosed = { [weak self, weak player] in
            player?.returnFromPictureInPicture()
            player?.onPictureInPicturePauseChange = nil
            self?.pipPlayer = nil
        }
        player.onPictureInPicturePauseChange = { [weak self] paused in self?.pip.setPlaying(!paused) }
        // PiP's "return to app" button: switch to Velvet's window (and its Space), like Safari.
        pip.onRestoreRequested = { [weak self] in self?.bringToFront() }
        pip.enter(view: view, aspect: player.videoSize ?? CGSize(width: 16, height: 9), playing: !player.isPaused,
                  returnTo: returnView?.window, rect: rect, automatic: automatic)
        if pipReason != .scrolledPast { releaseHiddenPageMemory() }
    }

    func exitPictureInPicture() {
        guard pip.isActive else { return }
        let inline = pipPlayer?.inlineView
        pip.exit(returnTo: inline?.window, rect: inline.map { $0.convert($0.bounds, to: nil) })
    }

    /// Scrolling the watch page: move the video into PiP once the player is mostly out of view,
    /// and back once it's mostly visible again (hysteresis avoids flicker at the edge).
    private func playerVisibilityChanged() {
        guard settings.pipOnScroll, watching != nil, !playerFullscreen,
              mainWindow?.occlusionState.contains(.visible) ?? true else { return }
        let fraction = playerVisibleFraction
        if !pip.isActive {
            guard fraction < 0.33, let player = activePlayer, !player.isPaused, player.position > 0 else { return }
            enterPictureInPicture(automatic: true, reason: .scrolledPast)
        } else if pipReason == .scrolledPast, fraction > 0.5 {
            exitPictureInPicture()
        }
    }

    /// After PiP's restore button, don't let automatic PiP re-trigger while we switch back.
    @ObservationIgnored private var suppressAutoPiPUntil = Date.distantPast

    /// Brings Velvet's window forward from another app. Since macOS 14, a self-requested
    /// `NSApp.activate()` is ignored while the user is in another app (cooperative activation),
    /// so ask LaunchServices to open Velvet instead — like a Dock click, which switches Spaces.
    private func bringToFront() {
        suppressAutoPiPUntil = Date().addingTimeInterval(4)
        NSApp.activate()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] _, _ in
            Task { @MainActor in self?.mainWindow?.makeKeyAndOrderFront(nil) }
        }
    }

    @ObservationIgnored private var scrollMonitor: Any?

    /// The inline player floats above the page (see PlayerLayer), so wheel/trackpad scrolling
    /// over it would never reach the page. Forward those events to the page's scroll view.
    private func installScrollForwarding() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread; NSEvent just isn't marked Sendable.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.watching != nil, !self.playerFullscreen,
                      let window = self.mainWindow, event.window === window,
                      let content = window.contentView else { return false }
                // SwiftUI's .global space here is the content view with a top-left origin.
                let p = event.locationInWindow
                let point = CGPoint(x: p.x, y: content.bounds.height - p.y)
                guard self.playerSlot.contains(point), self.watchViewport.contains(point),
                      let scrollView = Self.largestScrollView(in: content, containing: event.locationInWindow) else { return false }
                scrollView.scrollWheel(with: event)
                return true
            }
            return consumed ? nil : event
        }
    }

    /// The page's main scroll view: the largest NSScrollView under the point.
    private static func largestScrollView(in root: NSView, containing windowPoint: NSPoint) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ v: NSView) {
            if let sv = v as? NSScrollView, !sv.isHidden,
               sv.convert(sv.bounds, to: nil).contains(windowPoint),
               sv.bounds.height * sv.bounds.width > (best.map { $0.bounds.height * $0.bounds.width } ?? 0) {
                best = sv
            }
            v.subviews.forEach(visit)
        }
        visit(root)
        return best
    }

    private func observeWindow() {
        installScrollForwarding()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        guard let mainWindow else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: mainWindow, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowVisibilityChanged() }
        }
    }

    /// Swiping to another Space (or minimizing/covering the window) hides it: continue the
    /// playing video in PiP. Coming back ends an automatic PiP.
    private func windowVisibilityChanged() {
        guard let window = mainWindow else { return }
        let visible = window.occlusionState.contains(.visible)
        if !visible {
            guard settings.autoPictureInPicture, !pip.isActive, Date() > suppressAutoPiPUntil,
                  let player = activePlayer, !player.isPaused, player.duration > 0 || player.position > 0 else { return }
            enterPictureInPicture(automatic: true, reason: .windowHidden)
        } else {
            // Back on Velvet: the post-restore pause has done its job (it only exists to stop a
            // re-PiP loop if switching back failed), so switching away again should PiP at once.
            suppressAutoPiPUntil = .distantPast
            // Coming back: end a window-hidden PiP, unless the player is scrolled out of view
            // (then it stays in PiP, as if it had been scrolled past).
            if pip.isActive && pip.startedAutomatically {
                if playerVisibleFraction > 0.5 { exitPictureInPicture() } else { pipReason = .scrolledPast }
            }
        }
    }

    /// The page behind the player isn't visible (fullscreen/PiP): drop decoded thumbnails
    /// (they reload from the disk cache in milliseconds) and return freed heap pages.
    private func releaseHiddenPageMemory() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "VelvetNoRelief") { return } // for A/B measurement
        #endif
        Task { await ImagePipeline.shared.clearMemory() }
        MemoryRelief.soon()
    }

    // MARK: - Channels

    /// The open channel page (shown under any video opened from it, so Back returns here).
    private(set) var channel: ChannelModel?

    func openChannel(_ channelId: String) {
        guard channel?.id != channelId || watching != nil || shortsOverlay != nil else { return }
        closePlayer()
        shortsTab?.pause()
        if channel?.id != channelId {
            channel = ChannelModel(channelId: channelId, client: client,
                                   isSignedIn: { [weak self] in self?.authState == .signedIn })
        }
    }

    func closeChannel() { channel = nil }

    // MARK: - Shorts

    /// Shorts opened from a feed (seeded with the one you clicked); shown over the current page.
    private(set) var shortsOverlay: ShortsController?
    /// The sidebar Shorts tab (YouTube picks the first one).
    private(set) var shortsTab: ShortsController?

    func openShorts(startingWith video: Video) {
        watching?.close(); watching = nil
        shortsTab?.pause()
        shortsOverlay?.close()
        shortsOverlay = ShortsController(sequence: ShortsSequence(seed: video, client: client), app: self)
    }



    /// True when entering player fullscreen also put the window into macOS fullscreen,
    /// so leaving it should take the window back out (and only then).
    @ObservationIgnored private var playerOwnsWindowFullscreen = false

    func togglePlayerFullscreen() {
        let window = mainWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        let windowIsFullscreen = window?.styleMask.contains(.fullScreen) ?? false
        // Sidebar collapse + player growth animate together; the video scales along smoothly.
        let animation = Animation.smooth(duration: 0.35)
        log.debug("player fullscreen → \(!self.playerFullscreen, privacy: .public) from \(Thread.callStackSymbols.dropFirst(1).prefix(4).map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined() }.joined(separator: " ← "), privacy: .public)")
        if !playerFullscreen {
            withAnimation(animation) { playerFullscreen = true }
            releaseHiddenPageMemory()
            playerOwnsWindowFullscreen = !windowIsFullscreen
            if !windowIsFullscreen { window?.toggleFullScreen(nil) }
        } else {
            withAnimation(animation) { playerFullscreen = false }
            if playerOwnsWindowFullscreen && windowIsFullscreen { window?.toggleFullScreen(nil) }
            playerOwnsWindowFullscreen = false
        }
    }

    /// The window left macOS fullscreen on its own (green button, Esc, Mission Control).
    func windowDidExitFullscreen() {
        if playerOwnsWindowFullscreen { withAnimation(.smooth(duration: 0.35)) { playerFullscreen = false } }
        playerOwnsWindowFullscreen = false
    }

    /// Resolves streams ahead of a likely click (hovering a card).
    func prefetch(_ video: Video) {
        guard settings.prefetchOnHover, video.kind != .upcoming else { return }
        Task { await resolver.prefetch(video.id, isLive: video.kind == .live) }
    }

    func navigate(to destination: Destination) {
        closePlayer()
        channel = nil
        if destination != .shorts { shortsTab?.pause() }
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

    /// YouTube's own Live page (works signed out too): Live Now, News, Gaming, Sports, Upcoming…
    @ObservationIgnored private(set) lazy var liveFeed = SectionedFeedModel(browseId: "UC4R8DWoMoI7CAwX8_LjQHig", client: client)
    private(set) var historyFeed: SectionedFeedModel?
    private(set) var watchLaterFeed: SectionedFeedModel?
    private(set) var playlistsModel: PlaylistsModel?

    private func rebuildAccountFeeds() {
        // Shorts are personalized too; rebuilt once the account state is known.
        shortsTab?.close()
        shortsTab = authState == .unknown ? nil
            : ShortsController(sequence: ShortsSequence(seed: nil, client: client), app: self)
        let signedIn = authState == .signedIn
        homeFeed = signedIn ? FeedModel(source: .browse("FEwhat_to_watch"), client: client) : nil
        historyFeed = signedIn ? SectionedFeedModel(browseId: "FEhistory", client: client) : nil
        watchLaterFeed = signedIn ? SectionedFeedModel(browseId: "VLWL", client: client) : nil
        playlistsModel = signedIn ? PlaylistsModel(client: client) : nil
    }

    func libraryFeed(for destination: Destination) -> SectionedFeedModel? {
        switch destination {
        case .history: historyFeed
        case .watchLater: watchLaterFeed
        default: nil
        }
    }

    /// Restores a saved session at launch.
    func start() async {
        guard authState == .unknown else { return }
        prepareTools()
        if let saved = YouTubeSession.restore() {
            await activate(saved)
        } else {
            authState = .signedOut
            authRevision += 1
        }
        #if DEBUG
        if let id = UserDefaults.standard.string(forKey: "VelvetChannel"), !id.isEmpty { openChannel(id) }
        // `-VelvetScrollPiPTest YES` (with -VelvetPlay): scroll the page down at 9s, back up at 15s.
        if UserDefaults.standard.bool(forKey: "VelvetScrollPiPTest") {
            Task {
                @MainActor func scroll(to y: CGFloat) {
                    guard let content = mainWindow?.contentView,
                          let sv = Self.largestScrollView(in: content, containing: NSPoint(x: content.bounds.midX, y: content.bounds.midY)) else { return }
                    // Scroll like a user would (works for flipped and unflipped documents).
                    guard let doc = sv.documentView else { return }
                    let top = doc.isFlipped ? y : doc.bounds.height - y - sv.contentView.bounds.height
                    doc.scrollToVisible(NSRect(x: 0, y: max(0, top), width: 1, height: sv.contentView.bounds.height))
                }
                try? await Task.sleep(for: .seconds(9)); scroll(to: 900)
                try? await Task.sleep(for: .seconds(6)); scroll(to: 0)
            }
        }
        if let id = UserDefaults.standard.string(forKey: "VelvetHomeThenPlay"), !id.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(10))
                open(Video(id: id, title: "Scenario \(id)"), at: 60)
                try? await Task.sleep(for: .seconds(8))
                togglePlayerFullscreen()
            }
        }
        // `-VelvetPlay <videoId>` opens straight into the player (after the session restores).
        if let id = UserDefaults.standard.string(forKey: "VelvetPlay"), !id.isEmpty {
            let start = UserDefaults.standard.double(forKey: "VelvetStart")
            open(Video(id: id, title: "Debug: \(id)"), at: start > 0 ? start : nil)
            // `-VelvetPiPTest YES`: enter PiP after 6s, pause in PiP, leave after 12s.
            if UserDefaults.standard.bool(forKey: "VelvetPiPTest") {
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    enterPictureInPicture(automatic: false)
                    try? await Task.sleep(for: .seconds(3))
                    watching?.player.pause()
                    try? await Task.sleep(for: .seconds(3))
                    exitPictureInPicture()
                }
            }
            // (scenario) `-VelvetHomeThenPlay <id>`: let Home load, then play <id> and go fullscreen.
            // `-VelvetLeakTest YES`: open three more videos 8s apart (old players must be freed).
            if UserDefaults.standard.bool(forKey: "VelvetLeakTest") {
                Task {
                    for vid in ["aqz-KE-bpKQ", "jNQXAC9IVRw", "dQw4w9WgXcQ"] {
                        try? await Task.sleep(for: .seconds(8))
                        open(Video(id: vid, title: "Leak test \(vid)"), at: 30)
                    }
                }
            }
            // `-VelvetFullscreenTest YES`: show the sidebar, player fullscreen at 6s, back at 12s.
            if UserDefaults.standard.bool(forKey: "VelvetFullscreenTest") {
                sidebarVisibility = .all
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    togglePlayerFullscreen()
                    try? await Task.sleep(for: .seconds(6))
                    togglePlayerFullscreen()
                }
            }
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
