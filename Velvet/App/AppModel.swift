import SwiftUI
import OSLog

/// Sidebar destinations.
enum Destination: String, Hashable, CaseIterable, Identifiable {
    case home, subscriptions, shorts, live, history, watchLater, playlists, queue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .subscriptions: "Subscriptions"
        case .shorts: "Shorts"
        case .live: "Live"
        case .history: "History"
        case .watchLater: "Watch Later"
        case .playlists: "Playlists"
        case .queue: "Queue"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .subscriptions: "play.square.stack"
        case .shorts: "play.rectangle.on.rectangle"
        case .live: "dot.radiowaves.left.and.right"
        case .history: "clock.arrow.circlepath"
        case .watchLater: "clock"
        case .playlists: "list.bullet.rectangle"
        case .queue: "list.number"
        }
    }
}

/// A page you can go back or forward to (a browser-style history entry).
enum Route: Equatable {
    case destination(Destination, playlist: PlaylistSummary?)
    case search(String)
    case channel(String)
    case video(Video)

    static func == (a: Route, b: Route) -> Bool {
        switch (a, b) {
        case let (.destination(d1, p1), .destination(d2, p2)): d1 == d2 && p1?.id == p2?.id
        case let (.search(q1), .search(q2)): q1 == q2
        case let (.channel(c1), .channel(c2)): c1 == c2
        case let (.video(v1), .video(v2)): v1.id == v2.id
        default: false
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
    @ObservationIgnored private(set) lazy var aiFilter = AIChannelFilter(preferences: settings)
    @ObservationIgnored private(set) lazy var series = SeriesTracker(client: client)
    @ObservationIgnored private(set) lazy var searchAssist = SearchAssist(client: client, preferences: settings,
                                                                      account: { [weak self] in await self?.signedInSession })

    /// A suggestion clicked (or picked with ↑/↓ and Return): search for it.
    func pickSuggestion(_ text: String) {
        searchText = text
        searchAssist.isActive = false
        searchBlurRequest += 1
        submitSearch()
    }

    /// Bumped to take the cursor out of the search field (after picking a suggestion).
    var searchBlurRequest = 0

    /// A series episode's page has loaded: track it, and with nothing queued, queue the next
    /// episode so it plays when this one ends.
    func noteSeriesEpisode(_ session: PlayerSession, details: WatchDetails) async {
        guard settings.seriesTracking, !session.isLive else { return }
        let entry = await series.watching(session.video, title: details.title,
                                          channelId: details.channel?.id, channelName: details.channel?.name)
        guard let entry, let next = entry.next, watching === session, queue.isEmpty else { return }
        queue.start([session.video, next.video], at: 0, source: entry.name)
    }

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

    let alerts = SystemNotifications()
    let updates = UpdateController()
    /// Bumped to open the Settings window (only a view can call `openSettings`).
    var settingsOpenRequest = 0
    /// The pane the Settings window should show next; it clears this once shown.
    var requestedSettingsPane: SettingsPane?

    func openSettings(_ pane: SettingsPane) {
        requestedSettingsPane = pane
        settingsOpenRequest += 1
    }
    @ObservationIgnored private(set) lazy var inbox = InboxModel(client: client, preferences: settings, alerts: alerts)
    var showingInbox = false
    var showingAccount = false {
        // A failed account fetch gets another try when you look for it.
        didSet { if showingAccount, account == nil, authState == .signedIn { Task { await refreshAccount() } } }
    }

    init() {
        destination = settings.startPage
        alerts.onOpen = { [weak self] video in
            self?.bringToFront()
            self?.open(video)
        }
        alerts.onOpenUpdate = { [weak self] in
            self?.bringToFront()
            self?.openSettings(.about)
        }
        updates.onFound = { [weak self] release in
            Task { await self?.alerts.postUpdate(release) }
        }
        #if DEBUG
        // `-VelvetSearch "query"` opens straight into results; handy for testing.
        if let q = UserDefaults.standard.string(forKey: "VelvetSearch"), !q.isEmpty {
            searchText = q
            activeSearch = q
        }
        #endif
    }

    // MARK: - History (Back / Forward, swipes)

    @ObservationIgnored private var backStack: [Route] = []
    private(set) var forwardStack: [Route] = []
    /// Bumped when the back stack changes (it's not observed itself, to keep it cheap).
    private(set) var historyRevision = 0
    @ObservationIgnored private var applyingHistory = false

    /// The page on screen, as a history entry (Shorts opened over a page aren't one).
    var currentRoute: Route {
        if let watching, !watchPageHidden { return .video(watching.video) }
        if let channel { return .channel(channel.id) }
        if let activeSearch { return .search(activeSearch) }
        let d = destination ?? .home
        return .destination(d, playlist: d == .playlists ? openPlaylist : nil)
    }

    /// Call before a navigation you made: where you were becomes a Back step.
    func recordNavigation() {
        guard !applyingHistory else { return }
        let here = currentRoute
        if backStack.last != here { backStack.append(here) }
        if backStack.count > 50 { backStack.removeFirst() }
        forwardStack.removeAll()
        historyRevision += 1
    }

    var canGoBack: Bool {
        _ = historyRevision
        let here = currentRoute
        return shortsOverlay != nil || backStack.contains { $0 != here }
    }

    var canGoForward: Bool { shortsOverlay == nil && !forwardStack.isEmpty }

    func goBack() {
        // Shorts opened over a page close back to it (and resume a video they paused).
        if shortsOverlay != nil { backFromShorts(); return }
        let here = currentRoute
        while let route = backStack.popLast() {
            guard route != here else { continue }
            forwardStack.append(here)
            historyRevision += 1
            apply(route)
            return
        }
        historyRevision += 1
    }

    func goForward() {
        guard shortsOverlay == nil, let route = forwardStack.popLast() else { return }
        backStack.append(currentRoute)
        historyRevision += 1
        apply(route)
    }

    private func apply(_ route: Route) {
        applyingHistory = true
        defer { applyingHistory = false }
        switch route {
        case let .destination(d, playlist):
            navigate(to: d)
            openPlaylist = playlist
            searchText = ""
        case let .search(query):
            searchText = query
            submitSearch()
        case let .channel(id):
            openChannel(id)
        case let .video(video):
            open(video)
        }
    }

    func submitSearch() {
        recordNavigation()
        leaveWatchPage()
        channel = nil
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearch = q.isEmpty ? nil : q
        searchAssist.searched(q)
    }

    // MARK: - Playback

    /// The video being watched; non-nil shows the watch page (unless `watchPageHidden`).
    private(set) var watching: PlayerSession?
    /// The user browsed away from the watch page while its video carries on in PiP.
    private(set) var watchPageHidden = false
    /// The watch page is what the window shows right now.
    var isShowingWatchPage: Bool { watching != nil && !watchPageHidden }
    var playerFullscreen = false
    /// Where the watch page lays out the player, and the page's visible area (root coordinates).
    /// The player itself is drawn in a window-level layer (RootView) so fullscreen is a single
    /// frame animation over everything, sidebar included.
    /// The sidebar is (or is animating to being) a narrow icon rail. Grids pick their column
    /// count from this.
    var isSidebarCollapsed = UserDefaults.standard.bool(forKey: "Sidebar.collapsed") {
        didSet {
            #if DEBUG
            // Test copies share the installed app's defaults; don't change the user's sidebar.
            return
            #else
            UserDefaults.standard.set(isSidebarCollapsed, forKey: "Sidebar.collapsed")
            #endif
        }
    }
    /// How much wider the page gets when the sidebar collapses to its rail.
    var sidebarWidth: CGFloat { SidebarMetrics.fullWidth - SidebarMetrics.railWidth }

    func toggleSidebar() {
        withAnimation(Self.sidebarAnimation) { isSidebarCollapsed.toggle() }
    }

    /// Bumped to put the cursor in the search field (⌘F, ⌘K).
    var searchFocusRequest = 0
    /// Close to the split view's own slide, so grids move in step with the sidebar.
    static let sidebarAnimation: Animation = {
        #if DEBUG
        // `-VelvetSlowSidebar YES`: 10× slower grid animation, to inspect it frame by frame.
        if UserDefaults.standard.bool(forKey: "VelvetSlowSidebar") { return .smooth(duration: 3) }
        #endif
        return .smooth(duration: 0.3)
    }()
    var playerSlot: CGRect = .zero { didSet { playerVisibilityChanged() } }
    /// The watch page's list sizes, for the scroll test.
    @ObservationIgnored nonisolated(unsafe) static var testWatchCounts: (@MainActor () -> String)?
    /// Until when slot moves animate (switching theater mode); otherwise the player follows
    /// its slot at once (scrolling, resizing).
    @ObservationIgnored private var animateSlotUntil = Date.distantPast
    private static let theaterAnimation = Animation.smooth(duration: 0.3)

    /// Where each layout puts the player (key: theater mode). While the layout switches, the
    /// outgoing slot is still on screen and still reports its frame, sometimes after the new
    /// one; only the current mode's slot may move the player.
    @ObservationIgnored private var slots: [Bool: CGRect] = [:]

    func updatePlayerSlot(_ slot: CGRect, theater: Bool) {
        slots[theater] = slot
        guard theater == settings.theaterMode else { return }
        setPlayerSlot(slot)
    }

    private func setPlayerSlot(_ slot: CGRect) {
        guard slot != playerSlot else { return }
        if Date() < animateSlotUntil {
            withAnimation(Self.theaterAnimation) { playerSlot = slot }
        } else {
            playerSlot = slot
        }
    }

    /// T: the player spans the page, or goes back into its column. Rapid presses just retarget
    /// the animation.
    func toggleTheaterMode() {
        guard isShowingWatchPage, !playerFullscreen else { return }
        animateSlotUntil = Date().addingTimeInterval(0.5)
        withAnimation(Self.theaterAnimation) { settings.theaterMode.toggle() }
        // Go straight for the other layout's last known slot: a slot view that never left the
        // screen (toggled back mid-animation) won't report a change.
        if let known = slots[settings.theaterMode] { setPlayerSlot(known) }
    }
    var watchViewport: CGRect = .zero { didSet { playerVisibilityChanged() } }

    /// How much of the inline player is inside the watch page's visible area (0…1).
    var playerVisibleFraction: CGFloat {
        guard playerSlot.height > 0, !watchViewport.isEmpty else { return 1 }
        let visible = playerSlot.intersection(watchViewport)
        return visible.isNull ? 0 : visible.height / playerSlot.height
    }

    /// The session whose video is on screen (watch page, Shorts overlay, Shorts tab).
    var currentSession: PlayerSession? {
        if let watching { return watching }
        if let shortsOverlay { return shortsOverlay.session }
        if destination == .shorts, activeSearch == nil { return shortsTab?.session }
        return nil
    }

    @ObservationIgnored lazy var nowPlaying = NowPlaying { [weak self] in self?.currentSession }

    func makeSession(for video: Video) -> PlayerSession {
        let s = PlayerSession(video: video, resolver: resolver, preferences: settings,
                              client: client, session: authState == .signedIn ? session : nil,
                              progress: progress,
                              isSignedIn: { [weak self] in self?.authState == .signedIn })
        s.page.accountName = { [weak self] in self?.account?.name }
        s.page.accountPhoto = { [weak self] in self?.account?.photo }
        s.onQualityLowered = { [weak self] label in self?.showToast("Lowered to \(label) to stop buffering") }
        s.player.onEnded = { [weak self, weak s] in
            guard let self, let s, s === self.watching, self.settings.queueAutoAdvance else { return }
            self.playNextInQueue()
        }
        return s
    }

    /// Opens a video. Shorts open in the vertical Shorts player; other videos resume where you left off.
    func open(_ video: Video, at position: Double? = nil) {
        if video.kind != .short { recordNavigation() }
        pipHandoff = nil // a queued video still loading for PiP is dropped (its task closes it)
        // The video set aside for a Short: carry on where it was rather than starting over.
        if let suspended = suspendedWatch, suspended.video.id == video.id, position == nil {
            backFromShorts()
            return
        }
        if video.kind == .short && position == nil {
            openShorts(startingWith: video)
            return
        }
        // The video already playing in PiP: just bring its page back.
        if let watching, watching.video.id == video.id, watchPageHidden, position == nil {
            showWatchPage()
            return
        }
        watchPageHidden = false
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
        pipHandoff = nil
        suspendedWatch?.close()
        suspendedWatch = nil
        watchPageHidden = false
        if pip.isActive { exitPictureInPicture() }
        if playerFullscreen { togglePlayerFullscreen() }
        watching?.close()
        watching = nil
        shortsOverlay?.close()
        shortsOverlay = nil
    }

    // MARK: - Picture in Picture

    @ObservationIgnored let pip = PictureInPicture()
    @ObservationIgnored private var pipTimelineTask: Task<Void, Never>?
    /// The main window, reported by RootView; watched for visibility to drive automatic PiP.
    @ObservationIgnored weak var mainWindow: NSWindow? {
        didSet { if mainWindow !== oldValue { observeWindow() } }
    }
    @ObservationIgnored private var occlusionObserver: NSObjectProtocol?
    @ObservationIgnored private var fullscreenObservers: [NSObjectProtocol] = []
    /// The window is in (or going into) macOS fullscreen: no title bar or window buttons.
    var windowFullscreen = false

    /// The toolbar should only come down with the menu bar in fullscreen (RootView sets that),
    /// but macOS reads the setting when a window enters fullscreen. A window restored in
    /// fullscreen at launch never enters it, and keeps the toolbar as an opaque band over the
    /// top bar until it's minimized and back. So set it on the app directly.
    func hideToolbarInFullscreen() {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            let options = NSApp.presentationOptions
            // AppKit throws for this option unless fullscreen's own options are in effect.
            guard options.contains(.fullScreen), options.contains(.autoHideMenuBar),
                  !options.contains(.autoHideToolbar) else { return }
            NSApp.presentationOptions = options.union(.autoHideToolbar)
            log.info("Fullscreen at launch: toolbar set to auto-hide")
        }
    }
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
    enum PiPReason { case manual, windowHidden, scrolledPast, navigatedAway }
    @ObservationIgnored private var pipReason: PiPReason = .manual

    func enterPictureInPicture(automatic: Bool, reason: PiPReason? = nil) {
        pipReason = reason ?? (automatic ? .windowHidden : .manual)
        guard PictureInPicture.isAvailable, !pip.isActive, let player = activePlayer else { return }
        // Stay in player fullscreen: coming back should return the video right where it was.
        let returnView = player.inlineView
        let rect = returnView.map { $0.convert($0.bounds, to: nil) }
        let view = player.makePictureInPictureView()
        let session = watching ?? shortsOverlay?.session ?? shortsTab?.session
        // Start PiP from where the video is on the page (not the screen's corner): put the PiP
        // view exactly over the inline player first; PiP animates from a view's current frame.
        if let returnView, let content = returnView.window?.contentView {
            view.frame = returnView.convert(returnView.bounds, to: content)
            content.addSubview(view)
        }
        pipPlayer = player
        pip.onPlay = { [weak player] in player?.play() }
        pip.onPause = { [weak player] in player?.pause() }
        pip.onSkip = { [weak self, weak player] delta in
            guard let player else { return }
            player.seek(by: delta)
            // Reflect the jump in the PiP timeline right away instead of on the next tick.
            self?.pip.updatePlayback(duration: player.duration, elapsed: player.position, rate: player.speed,
                                     playing: !player.isPaused, live: false)
        }
        pip.onSkipToLive = { [weak self] in (self?.watching ?? self?.shortsOverlay?.session)?.goLive() }
        pip.onClosed = { [weak self, weak player] restored in
            player?.returnFromPictureInPicture()
            player?.onPictureInPicturePauseChange = nil
            guard let self else { return }
            self.pipPlayer = nil
            let ours = self.closingPiPOurselves
            self.closingPiPOurselves = false
            // PiP was carrying a video whose page is gone: ✕ ends it, "return" reopens the page.
            // If Velvet closed it itself, keep the video: show its page rather than stop it.
            if self.watchPageHidden, let watching = self.watching, watching.player === player {
                if restored || ours { self.watchPageHidden = false } else { self.closePlayer() }
            }
        }
        player.onPictureInPicturePauseChange = { [weak self] paused in self?.pip.setPlaying(!paused) }
        let live = session?.isLive ?? false
        pipTimelineTask?.cancel()
        pipTimelineTask = Task { [weak self, weak player] in
            // Keep the system PiP's timeline current (cheap; once a second).
            while let self, let player, self.pip.isActive, !Task.isCancelled {
                self.pip.updatePlayback(duration: player.duration, elapsed: player.position, rate: player.speed,
                                        playing: !player.isPaused, live: live)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // PiP's "return to app" button: switch to Velvet's window (and its Space), like Safari.
        pip.onRestoreRequested = { [weak self] in
            guard let self else { return }
            self.bringToFront()
            // Reopen the page now so it's there when PiP flies back into it.
            if self.watchPageHidden { self.watchPageHidden = false }
        }
        pip.useFloatingWindow = settings.pipStyle == .floating
        pip.returnRectProvider = { [weak player] in
            guard let inline = player?.inlineView, let window = inline.window else { return nil }
            return window.convertToScreen(inline.convert(inline.bounds, to: nil))
        }
        let entered = pip.enter(view: view, aspect: player.videoSize ?? CGSize(width: 16, height: 9), playing: !player.isPaused,
                                returnTo: returnView?.window, rect: rect, automatic: automatic,
                                player: player, isLive: live)
        guard entered else {
            // Never leave the video in an orphaned PiP view over the page.
            view.removeFromSuperview()
            player.returnFromPictureInPicture()
            player.onPictureInPicturePauseChange = nil
            pipPlayer = nil
            pipTimelineTask?.cancel()
            return
        }
        player.leaveStillOnPage()
        if pipReason != .scrolledPast { releaseHiddenPageMemory() }
    }

    /// Leaving the watch page (sidebar, search, channel, Back): keep the video going in PiP
    /// if enabled, otherwise close it.
    /// `forcePictureInPicture`: the user asked for PiP explicitly (the I key), so the
    /// "keep playing when leaving" preference doesn't apply.
    func leaveWatchPage(forcePictureInPicture: Bool = false) {
        returnFromPiPTask?.cancel()
        guard let watching, !watchPageHidden else {
            if shortsOverlay != nil { closePlayer() }
            return
        }
        guard settings.pipOnNavigate || forcePictureInPicture, PictureInPicture.isAvailable, watching.phase == .ready else {
            closePlayer()
            return
        }
        if playerFullscreen { togglePlayerFullscreen() }
        if !pip.isActive { enterPictureInPicture(automatic: false, reason: .navigatedAway) }
        pipReason = .navigatedAway
        watchPageHidden = true
    }

    /// Back to the page of the video playing in PiP.
    @ObservationIgnored private var returnFromPiPTask: Task<Void, Never>?

    func showWatchPage() {
        guard watchPageHidden else { return }
        watchPageHidden = false
        // Let the page lay out its player so PiP can animate back into it. Cancelled if the
        // page is left again first (I pressed twice quickly).
        returnFromPiPTask?.cancel()
        returnFromPiPTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, !watchPageHidden else { return }
            exitPictureInPicture()
        }
    }

    /// Set while Velvet closes PiP itself, so the close isn't taken for the user's ✕.
    @ObservationIgnored private var closingPiPOurselves = false

    func exitPictureInPicture() {
        guard pip.isActive else { return }
        closingPiPOurselves = true
        let inline = pipPlayer?.inlineView
        pip.exit(returnTo: inline?.window, rect: inline.map { $0.convert($0.bounds, to: nil) })
    }

    /// Scrolling the watch page: move the video into PiP once the player is mostly out of view,
    /// and back once it's mostly visible again (hysteresis avoids flicker at the edge).
    private func playerVisibilityChanged() {
        guard settings.pipOnScroll, isShowingWatchPage, !playerFullscreen else { return }
        let fraction = playerVisibleFraction
        if !pip.isActive {
            guard fraction < 0.33 else { return }
            guard mainWindow?.occlusionState.contains(.visible) ?? true else {
                log.debug("Scrolled past the player, but the window reports itself hidden: no PiP")
                return
            }
            guard let player = activePlayer, !player.isPaused, player.position > 0 else {
                log.debug("Scrolled past the player, but it isn't playing: no PiP")
                return
            }
            log.info("Scrolled past the player (\(Int(fraction * 100))% visible): PiP")
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
    func bringToFront() {
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
    // MARK: - Swipe between pages

    /// How far a two-finger swipe has gone: towards Back (0…1) or Forward (0…-1). Drives the
    /// arrow that slides in from the edge.
    private(set) var swipeAmount: CGFloat = 0

    /// Starts tracking a sideways two-finger swipe (the one Safari uses for Back/Forward),
    /// unless it should scroll something sideways instead. Returns whether it took the event.
    private func beginSwipeIfNeeded(_ event: NSEvent) -> Bool {
        guard event.phase == .began, event.hasPreciseScrollingDeltas,
              NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              let window = mainWindow, event.window === window, !playerFullscreen,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 else { return false }
        // Fingers moving right reveal what's to the left: Back.
        let towardsBack = event.scrollingDeltaX > 0
        guard towardsBack ? canGoBack : canGoForward else { return false }
        if let content = window.contentView,
           Self.canScrollSideways(in: content, at: event.locationInWindow, towardsStart: towardsBack) { return false }
        let back = canGoBack, forward = canGoForward
        var navigated = false
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: forward ? -1 : 0, max: back ? 1 : 0) { [weak self] amount, phase, complete, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // .ended: let go past the threshold; .cancelled: not far enough (the arrow then
                // slides back out with the amounts that follow).
                if phase == .ended, !navigated {
                    navigated = true
                    // The arrow goes at once and the page changes. AppKit would go on animating
                    // the amount to ±1, but those frames came while the new page was being
                    // built and stuttered, which made a quick swipe feel laggy.
                    self.swipeAmount = 0
                    if towardsBack { self.goBack() } else { self.goForward() }
                    return
                }
                if navigated { return }
                self.swipeAmount = complete ? 0 : amount
            }
        }
        return true
    }

    /// A sideways-scrolling row (topic chips, a Shorts shelf) under the pointer that can still
    /// move in the swipe's direction gets the gesture; at its end, the swipe navigates.
    private static func canScrollSideways(in root: NSView, at windowPoint: NSPoint, towardsStart: Bool) -> Bool {
        // Walk the views rather than hit-test: SwiftUI's hosting views can answer a hit test
        // themselves, hiding the scroll views inside.
        func visit(_ v: NSView) -> Bool {
            if v.isHidden { return false }
            if let scroll = v as? NSScrollView, let document = scroll.documentView,
               scroll.convert(scroll.bounds, to: nil).contains(windowPoint) {
                let visible = scroll.contentView.bounds
                if document.frame.width > visible.width + 1,
                   towardsStart ? visible.minX > 1 : visible.maxX < document.frame.width - 1 { return true }
            }
            return v.subviews.contains(where: visit)
        }
        return visit(root)
    }

    @ObservationIgnored private var clickMonitor: Any?

    /// A click anywhere but the search field or its suggestions closes the suggestions and
    /// leaves the field (so the player's keys work again). The click still goes through.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                guard let self, self.searchAssist.isActive, let window = self.mainWindow, event.window === window,
                      let content = window.contentView else { return }
                let p = event.locationInWindow
                let point = CGPoint(x: p.x, y: content.bounds.height - p.y)
                let assist = self.searchAssist
                guard !assist.fieldFrame.contains(point), !(assist.isShowing && assist.dropdownFrame.contains(point)) else { return }
                assist.isActive = false
                self.searchBlurRequest += 1
            }
            return event
        }
    }

    private func installScrollForwarding() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread; NSEvent just isn't marked Sendable.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                if self?.beginSwipeIfNeeded(event) == true { return true }
                guard let self, self.isShowingWatchPage, !self.playerFullscreen,
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
    static func largestScrollView(in root: NSView, containing windowPoint: NSPoint) -> NSScrollView? {
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

    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var nextIKeyAllowed = Date.distantPast

    /// The I key in both directions: from the watch page to the page under it (video in PiP),
    /// and back. Handled app-wide because once the page is hidden there's no player view to
    /// receive keys. Ignored while typing (search, comments) and with ⌘/⌥/⌃.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.watching != nil, !self.playerFullscreen,
                      event.charactersIgnoringModifiers?.lowercased() == "i",
                      event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
                      event.window === self.mainWindow, !Self.isTyping(in: event.window) else { return false }
                // PiP's window animates in and out (~0.5 s); presses during that are swallowed
                // so its open and close can't interleave.
                guard Date() >= self.nextIKeyAllowed else { return true }
                self.nextIKeyAllowed = Date().addingTimeInterval(0.6)
                if self.watchPageHidden {
                    self.showWatchPage()
                } else if self.isShowingWatchPage {
                    self.leaveWatchPage(forcePictureInPicture: true)
                } else {
                    return false
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    private static func isTyping(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextField
    }

    private func observeWindow() {
        installScrollForwarding()
        installClickMonitor()
        installKeyMonitor()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        guard let mainWindow else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: mainWindow, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.mainWindow else { return }
                let visible = window.occlusionState.contains(.visible)
                self.log.info("Occlusion changed: visible=\(visible)")
                self.windowVisibilityChanged(visible: visible)
            }
        }
        #if DEBUG
        // `-VelvetFullscreenAtLaunch YES`: go fullscreen as soon as the window exists, like a
        // window restored in fullscreen.
        if UserDefaults.standard.bool(forKey: "VelvetFullscreenAtLaunch"), !mainWindow.styleMask.contains(.fullScreen) {
            mainWindow.toggleFullScreen(nil)
        }
        #endif
        windowFullscreen = mainWindow.styleMask.contains(.fullScreen)
        // A restored window may only report fullscreen a moment after it appears.
        log.info("Window fullscreen state at launch: \(self.windowFullscreen), options \(NSApp.presentationOptions.rawValue)")
        Task { [weak self] in
            for delay in [0.5, 1.5, 4.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, let window = self.mainWindow else { return }
                let toolbar = NSApp.windows.filter { $0 !== window && $0.frame.height == 52 }.map { "\($0.className) \(Int($0.frame.minY)) alpha \($0.alphaValue) visible \($0.isVisible)" }
                self.log.info("Fullscreen check: fullscreen \(window.styleMask.contains(.fullScreen)), options \(NSApp.presentationOptions.rawValue), toolbar visible \(window.toolbar?.isVisible ?? false), windows \(toolbar, privacy: .public)")
                if window.styleMask.contains(.fullScreen) { self.hideToolbarInFullscreen() }
            }
        }
        for observer in fullscreenObservers { NotificationCenter.default.removeObserver(observer) }
        fullscreenObservers = [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false)].map { name, entering in
            NotificationCenter.default.addObserver(forName: name, object: mainWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowFullscreen = entering }
            }
        } + [NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: mainWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideToolbarInFullscreen() }
        }]
        // Occlusion updates can trail a Space swipe by 2–3 s (seen on macOS 15). The Space
        // change itself is announced as soon as the swipe lands, so react to that too.
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.mainWindow, !window.isMiniaturized, window.isVisible else { return }
                let onSpace = window.isOnActiveSpace
                self.log.info("Space changed: window on active space=\(onSpace)")
                self.windowVisibilityChanged(visible: onSpace)
            }
        }
    }
    @ObservationIgnored private var spaceObserver: NSObjectProtocol?

    /// Swiping to another Space (or minimizing/covering the window) hides it: continue the
    /// playing video in PiP. Coming back ends an automatic PiP.
    private func windowVisibilityChanged(visible: Bool) {
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
            if pip.isActive && pip.startedAutomatically && !watchPageHidden {
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
        guard channel?.id != channelId || isShowingWatchPage || shortsOverlay != nil else { return }
        recordNavigation()
        leaveWatchPage()
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

    /// The video whose page a Short was opened from (e.g. its related Shorts). Back from the
    /// Shorts returns to it at the same moment instead of starting it over.
    private var suspendedWatch: PlayerSession?

    func openShorts(startingWith video: Video) {
        let fromWatchPage = isShowingWatchPage
        watchPageHidden = false
        if pip.isActive { exitPictureInPicture() }
        if playerFullscreen { togglePlayerFullscreen() }
        suspendedWatch?.close(); suspendedWatch = nil
        if fromWatchPage, let watching {
            watching.suspend()
            suspendedWatch = watching
        } else {
            watching?.close()
        }
        watching = nil
        shortsTab?.pause()
        shortsOverlay?.close()
        shortsOverlay = ShortsController(sequence: ShortsSequence(seed: video, client: client), app: self)
    }

    /// Back from Shorts opened over a page: to the suspended video if there is one.
    func backFromShorts() {
        guard let suspended = suspendedWatch else { closePlayer(); return }
        suspendedWatch = nil
        shortsOverlay?.close()
        shortsOverlay = nil
        watching = suspended
        suspended.resume()
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
        recordNavigation()
        // Shorts autoplay, so a video carried along in PiP would talk over them.
        if destination == .shorts { closePlayer() } else { leaveWatchPage() }
        shortsOverlay?.close(); shortsOverlay = nil
        channel = nil
        if destination != .shorts { shortsTab?.pause() }
        activeSearch = nil
        // The Playlists item goes back to the grid, like a tab bar's selected tab.
        if destination == .playlists { openPlaylist = nil }
        self.destination = destination
    }

    // MARK: - Queue

    let queue = PlaybackQueue()
    /// The next video, loading while the current one stays in PiP (see `continueInPictureInPicture`).
    @ObservationIgnored private var pipHandoff: PlayerSession?

    func addToQueue(_ video: Video) {
        queue.add(video)
        showToast("Added to queue")
    }

    func playNextQueued(_ video: Video) {
        queue.playNext(video)
        showToast("Will play next")
    }

    /// Plays the queue's first video. If the current one is in PiP while you browse, the
    /// next one continues there instead of taking over the window.
    func playNextInQueue() {
        guard let next = queue.popFirst() else { return }
        if watchPageHidden, pip.isActive, let current = watching {
            continueInPictureInPicture(with: next, replacing: current)
        } else {
            open(next)
        }
    }

    /// Plays a queued video now (from the Queue page), taking it out of the queue.
    /// A video clicked in a playlist: play it, with the rest of the playlist queued after it.
    func play(_ video: Video, inPlaylist videos: [Video], title: String) {
        // Shorts open their own player and upcoming videos can't play yet; skip both.
        let playable = videos.filter { ($0.kind != .short && $0.kind != .upcoming) || $0.id == video.id }
        let index = playable.firstIndex { $0.id == video.id } ?? 0
        queue.start(playable, at: index, source: title)
        open(video)
    }

    /// A video clicked in the queue panel: everything before it counts as played.
    func playFromQueue(_ video: Video) {
        guard let target = queue.jump(to: video.id) else { open(video); return }
        if watching?.video.id != target.id { open(target) }
    }

    /// Loads `next` while `current` holds the PiP window, then swaps them, so there's
    /// only a short gap and the page you're browsing is left alone.
    private func continueInPictureInPicture(with next: Video, replacing current: PlayerSession) {
        current.player.pause()
        let session = makeSession(for: next)
        pipHandoff = session
        session.start()
        Task {
            // Ready once the streams are loaded and mpv knows the length (≈ the first frame).
            for _ in 0..<300 {
                if case .failed = session.phase { break }
                if session.phase == .ready && session.player.duration > 0 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard pipHandoff === session else { session.close(); return }
            pipHandoff = nil
            // The PiP window still belongs to the old player: its close must not end the new one.
            watching = session
            exitPictureInPicture()
            for _ in 0..<40 where pip.isActive { try? await Task.sleep(for: .milliseconds(50)) }
            current.close()
            guard watching === session, watchPageHidden else { return }
            if case .failed = session.phase {
                // Nothing to show in PiP; open the page so the error is visible.
                watchPageHidden = false
                return
            }
            log.info("Queue: continuing in PiP with \(next.id, privacy: .public)")
            enterPictureInPicture(automatic: false, reason: .navigatedAway)
        }
    }

    // MARK: - Video actions (context menus)

    /// A short confirmation shown at the bottom of the window ("Saved to Watch Later").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// An action failed; shown as an alert.
    var actionError: String?
    /// Videos removed with "Not interested" / "Don't recommend channel"; feeds hide them.
    private(set) var dismissedVideos: Set<String> = []
    /// The video whose "Save to Playlist" sheet is open.
    var playlistPickerVideo: Video?

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func saveToWatchLater(_ video: Video) {
        guard authState == .signedIn else { actionError = "Sign in to use Watch Later."; return }
        Task {
            do {
                try await client.setVideo(video.id, inPlaylist: "WL", true)
                showToast("Saved to Watch Later")
            } catch {
                actionError = "Couldn't save to Watch Later: \(error.localizedDescription)"
            }
        }
    }

    /// "Not interested" (or, with `channel`, "Don't recommend channel"): tells YouTube and
    /// hides the video at once; for a channel, every loaded video from it.
    func sendFeedback(for video: Video, channel: Bool) {
        guard let token = channel ? video.dontRecommendChannelToken : video.notInterestedToken else { return }
        let hidden = channel && video.channelId != nil
            ? Set(homeFeed?.videos.filter { $0.channelId == video.channelId }.map(\.id) ?? []).union([video.id])
            : [video.id]
        dismissedVideos.formUnion(hidden)
        Task {
            do {
                try await client.feedback(token)
                showToast(channel ? "You won't be recommended this channel" : "Video removed from your recommendations")
            } catch {
                dismissedVideos.subtract(hidden)
                actionError = "Couldn't send that to YouTube: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Account

    enum AuthState: Equatable {
        case unknown, signedOut, signedIn
    }

    private(set) var authState: AuthState = .unknown
    private(set) var account: Account?
    private(set) var session: YouTubeSession?
    var signedInSession: YouTubeSession? { authState == .signedIn ? session : nil }
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
    /// Latest uploads from your subscriptions (YouTube's FEsubscriptions: a grid like Home's).
    private(set) var subscriptionsFeed: FeedModel?
    private(set) var playlistsModel: PlaylistsModel?
    /// The playlist open on the Playlists page (nil: the grid of all of them).
    var openPlaylist: PlaylistSummary?

    func open(_ playlist: PlaylistSummary) {
        navigate(to: .playlists)
        openPlaylist = playlist
    }

    private func rebuildAccountFeeds() {
        // Shorts are personalized too; rebuilt once the account state is known.
        shortsTab?.close()
        shortsTab = authState == .unknown ? nil
            : ShortsController(sequence: ShortsSequence(seed: nil, client: client), app: self)
        let signedIn = authState == .signedIn
        homeFeed = signedIn ? FeedModel(source: .browse("FEwhat_to_watch"), client: client) : nil
        homeFeed?.hidesPromotions = { [settings] in settings.hidePromotions }
        historyFeed = signedIn ? SectionedFeedModel(browseId: "FEhistory", client: client) : nil
        watchLaterFeed = signedIn ? SectionedFeedModel(browseId: "VLWL", client: client) : nil
        subscriptionsFeed = signedIn ? FeedModel(source: .browse("FEsubscriptions"), client: client) : nil
        subscriptionsFeed?.hidesPromotions = { [settings] in settings.hidePromotions }
        playlistsModel = signedIn ? PlaylistsModel(client: client) : nil
        openPlaylist = nil
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
        settings.appearance.apply()
        Task { await aiFilter.refreshIfNeeded() }
        guard authState == .unknown else { return }
        nowPlaying.start()
        updates.start { [weak self] in self?.settings.checkAppUpdates ?? false }
        prepareTools()
        if let saved = YouTubeSession.restore() {
            await activate(saved)
        } else {
            authState = .signedOut
            authRevision += 1
        }
        #if DEBUG
        // `-VelvetDumpJSON <videoId> -VelvetDumpDir <path>`: save raw (read-only) responses for
        // parser work: the watch page, its first comments and replies pages, and the home feed.
        if let id = UserDefaults.standard.string(forKey: "VelvetDumpJSON"), !id.isEmpty,
           let dir = UserDefaults.standard.string(forKey: "VelvetDumpDir") {
            Task {
                func save(_ json: JSON, _ name: String) {
                    try? json.data().write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
                do {
                    let watch = try await client.next(videoId: id)
                    save(watch, "watch.json")
                    let details = WatchParser.details(from: watch, videoId: id)
                    log.info("Dump: watch subscribed \(details?.isSubscribed ?? false), bell \(details?.bell?.setting?.label ?? "-", privacy: .public), \(details?.bell?.params.count ?? 0) choices")
                    if let token = WatchParser.details(from: watch, videoId: id)?.commentsToken {
                        let comments = try await client.next(continuation: token)
                        save(comments, "comments.json")
                        let page = WatchParser.comments(from: comments)
                        log.info("Dump: \(page.comments.count) comments, create=\(page.createParams != nil), reply=\(page.comments.filter { $0.actions.reply != nil }.count), like=\(page.comments.filter { $0.actions.like != nil }.count), edit=\(page.comments.filter { $0.actions.edit != nil }.count), delete=\(page.comments.filter { $0.actions.delete != nil }.count)")
                        if let r = WatchParser.comments(from: comments).comments.first(where: { $0.repliesToken != nil })?.repliesToken {
                            save(try await client.next(continuation: r), "replies.json")
                        }
                    }
                    let home = try await client.browse("FEwhat_to_watch")
                    save(home, "home.json")
                    let subs = try await client.browse("FEsubscriptions")
                    save(subs, "subscriptions.json")
                    if let token = VideoParser.continuations(in: subs).last {
                        save(try await client.browse(continuation: token), "subscriptions-2.json")
                    }
                    let videos = VideoParser.videos(in: home)
                    let promoted = Set(videos.map(\.id)).subtracting(VideoParser.videos(in: home, skipping: VideoParser.promotionKeys).map(\.id))
                    log.info("Dump: home promotions hidden: \(promoted.count)")
                    log.info("Dump: home \(videos.count) videos, notInterested=\(videos.filter { $0.notInterestedToken != nil }.count), dontRecommend=\(videos.filter { $0.dontRecommendChannelToken != nil }.count)")
                    if UserDefaults.standard.bool(forKey: "VelvetDumpNotifications") {
                        save(try await client.unseenNotificationCount(), "unseen.json")
                        save(try await client.notificationMenu(), "notifications.json")
                        save(try await client.browse("FEchannels"), "channels.json")
                        if let channel = UserDefaults.standard.string(forKey: "VelvetDumpChannel") {
                            let page = try await client.browse(channel)
                            save(page, "channel.json")
                            let bell = ChannelParser.header(from: page, channelId: channel)?.bell
                            log.info("Dump: channel bell \(bell?.setting?.label ?? "-", privacy: .public), \(bell?.params.count ?? 0) choices")
                        }
                        var token: String?
                        for page in 0..<6 {
                            let json = try await client.notificationMenu(continuation: token)
                            save(json, "inbox\(page).json")
                            token = NotificationParser.inbox(from: json).continuation
                            if token == nil { break }
                        }
                        let inbox = NotificationParser.inbox(from: try await client.notificationMenu())
                        log.info("Dump: inbox \(inbox.items.count) items, \(inbox.items.filter { $0.videoId != nil }.count) with video, \(inbox.items.filter { $0.readToken != nil }.count) with read token, more: \(inbox.continuation != nil)")
                    }
                    log.info("Dump finished")
                } catch {
                    log.error("Dump failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if let id = UserDefaults.standard.string(forKey: "VelvetChannel"), !id.isEmpty {
            openChannel(id)
            // `-VelvetChannelSearch "words"`: search inside the channel and log the results.
            if let q = UserDefaults.standard.string(forKey: "VelvetChannelSearch"), !q.isEmpty {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    channel?.search(q)
                    try? await Task.sleep(for: .seconds(5))
                    let results = channel?.searchResults
                    log.info("Test: channel search \(q, privacy: .public): \(results?.videos.count ?? -1) videos, first \(results?.videos.first?.title ?? "-", privacy: .public)")
                }
            }
        }
        // `-VelvetNavigateTest YES` (with -VelvetPlay): sidebar to History at 10s, reopen the video at 18s.
        if UserDefaults.standard.bool(forKey: "VelvetNavigateTest") {
            Task {
                try? await Task.sleep(for: .seconds(10))
                log.info("Test: navigating to History")
                navigate(to: .history)
                try? await Task.sleep(for: .seconds(8))
                if let v = watching?.video { log.info("Test: reopening video"); open(v) }
            }
        }
        // `-VelvetSidebarTest YES`: hide the sidebar at 8s and show it at 12s, like the toolbar button.
        if UserDefaults.standard.bool(forKey: "VelvetSidebarTest") {
            Task {
                for delay in [8.0, 4.0] {
                    try? await Task.sleep(for: .seconds(delay))
                    log.info("Test: toggling the sidebar")
                    toggleSidebar()
                }
            }
        }
        // `-VelvetShortsBackTest <shortId>` (with -VelvetPlay): open that Short at 8s, Back at 16s.
        if let short = UserDefaults.standard.string(forKey: "VelvetShortsBackTest"), !short.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(8))
                log.info("Test: opening a Short at \(Int(self.watching?.player.position ?? -1))s")
                open(Video(id: short, title: "Test short", kind: .short))
                try? await Task.sleep(for: .seconds(8))
                log.info("Test: Back from Shorts")
                backFromShorts()
                for _ in 0..<6 {
                    try? await Task.sleep(for: .seconds(1))
                    log.info("Test: back on \(self.watching?.video.id ?? "nothing", privacy: .public) at \(self.watching?.player.position ?? -1, format: .fixed(precision: 1))s, playing=\(!(self.watching?.player.isPaused ?? true)), loading=\(self.watching?.player.isLoading ?? false)")
                }
            }
        }
        // `-VelvetKeyTest "t,i,i"` (with -VelvetPlay): from 8s, press each key 4s apart, as real key events.
        if let keys = UserDefaults.standard.string(forKey: "VelvetKeyTest"), !keys.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(8))
                for token in keys.split(separator: ",").map(String.init) {
                    // "cmd+k" presses ⌘K.
                    let command = token.hasPrefix("cmd+")
                    let key = command ? String(token.dropFirst(4)) : token
                    let codes: [String: UInt16] = ["i": 34, "t": 17, "k": 40, "f": 3, "r": 15, "s": 1]
                    if let window = mainWindow, let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                        isARepeat: false, keyCode: codes[key] ?? 17) {
                        NSApp.postEvent(event, atStart: false)
                    }
                    // `-VelvetKeyGap <seconds>` (default 4) presses faster, e.g. 0.15 to mash a key.
                    let gap = UserDefaults.standard.double(forKey: "VelvetKeyGap")
                    try? await Task.sleep(for: .seconds(gap > 0 ? gap : 4))
                    log.info("Test: after \(token, privacy: .public): search=\(self.searchText, privacy: .public), suggestions=\(self.searchAssist.isActive ? self.searchAssist.rows.count : -1) (\(self.searchAssist.rows.filter(\.isHistory).count) yours: \(self.searchAssist.rows.prefix(3).map(\.text).joined(separator: " | "), privacy: .public)), queue=\(self.queue.items.count) from \(self.queue.source ?? "-", privacy: .public), watch page shown=\(self.isShowingWatchPage), hidden=\(self.watchPageHidden), PiP=\(self.pip.isActive), theater=\(self.settings.theaterMode), looping=\(self.watching?.player.isLooping ?? false), playing=\(!(self.watching?.player.isPaused ?? true))")
                }
            }
        }
        ControlsPreview.renderIfAsked()
        // `-VelvetAIFilterTest YES` (with `-settings.hideAIChannels '<true/>'`): log how many home
        // videos have a channel handle and how many the filter hides.
        if UserDefaults.standard.bool(forKey: "VelvetAIFilterTest") {
            Task {
                try? await Task.sleep(for: .seconds(12))
                let videos = homeFeed?.videos ?? []
                let known = videos.filter { $0.channelHandle != nil }
                let hidden = videos.filter { aiFilter.hides($0) }
                log.info("Test: AI filter: \(self.aiFilter.blocked.count) blocked, \(self.aiFilter.likely.count) likely; home \(videos.count) videos, \(known.count) with handles (e.g. \(known.first?.channelHandle ?? "-", privacy: .public)), \(hidden.count) hidden")
            }
        }
        // `-VelvetRelatedChipTest YES` (with -VelvetPlay): log the related chips, pick the second,
        // then go back to All, logging the related list each time.
        if UserDefaults.standard.bool(forKey: "VelvetRelatedChipTest") {
            Task {
                try? await Task.sleep(for: .seconds(8))
                guard let page = watching?.page else { return }
                log.info("Test: related chips \(page.relatedChips.map { "\($0.title)\($0.token == nil ? "*" : "")" }.joined(separator: ", "), privacy: .public); \(page.related.count) related")
                guard page.relatedChips.count > 1 else { return }
                let all = page.related.first?.title ?? "-"
                await page.selectRelatedChip(page.relatedChips[1])
                log.info("Test: \(page.relatedChips[1].title, privacy: .public): \(page.related.count) related, first \(page.related.first?.title ?? "-", privacy: .public)")
                await page.selectRelatedChip(page.relatedChips[0])
                log.info("Test: back to All: \(page.related.count) related, first unchanged \(page.related.first?.title == all)")
            }
        }
        // `-VelvetSubscriptionsTest YES`: open Subscriptions and log what loaded.
        if UserDefaults.standard.bool(forKey: "VelvetSubscriptionsTest") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                navigate(to: .subscriptions)
                try? await Task.sleep(for: .seconds(5))
                let feed = subscriptionsFeed
                let first = feed?.videos.count ?? -1
                await feed?.loadMore()
                let videos = feed?.videos ?? []
                log.info("Test: subscriptions: \(first) videos, \(videos.count) after a second page, \(feed?.shorts.count ?? 0) Shorts, first \(videos.first.map { "\($0.channelName ?? "?"): \($0.title) (\($0.published ?? ""))" } ?? "-", privacy: .public)")
            }
        }
        // `-VelvetSuggestTest YES`: print YouTube's signed-in search suggestions (raw) for "" and "s".
        if UserDefaults.standard.bool(forKey: "VelvetSuggestTest") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                for q in ["", "s"] {
                    var c = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")!
                    c.queryItems = [URLQueryItem(name: "client", value: "youtube"), URLQueryItem(name: "ds", value: "yt"),
                                    URLQueryItem(name: "hl", value: "en"), URLQueryItem(name: "gs_ri", value: "youtube"),
                                    URLQueryItem(name: "q", value: q), URLQueryItem(name: "xhr", value: "t")]
                    let data = (try? await client.get(c.url!)) ?? Data()
                    FileHandle.standardError.write(Data("SUGGEST[\(q)]: \(String(decoding: data, as: UTF8.self).prefix(1500))\n".utf8))
                }
                // What the dropdown shows for an empty box and for "4k", with My Activity merged in.
                for q in ["", "4k"] {
                    searchAssist.isActive = true
                    searchAssist.queryChanged(q)
                    try? await Task.sleep(for: .seconds(6))
                    let rows = searchAssist.rows.map { ($0.isHistory ? "🕘 " : "") + $0.text }.joined(separator: " | ")
                    FileHandle.standardError.write(Data("DROPDOWN[\(q)]: \(rows)\n".utf8))
                }
                searchAssist.isActive = false
            }
        }
        // `-VelvetSearchClickTest YES`: click the search field three times, then elsewhere, logging
        // whether the suggestions show after each click (they should: show, hide, show, hide).
        if UserDefaults.standard.bool(forKey: "VelvetSearchClickTest") {
            Task {
                try? await Task.sleep(for: .seconds(6))
                guard let window = mainWindow, let content = window.contentView else { return }
                @MainActor func click(_ p: CGPoint, _ name: String) async {
                    let location = NSPoint(x: p.x, y: content.bounds.height - p.y)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                    try? await Task.sleep(for: .seconds(2))
                    log.info("Test: after clicking \(name, privacy: .public): suggestions showing \(self.searchAssist.isShowing) (\(self.searchAssist.rows.count) rows), active \(self.searchAssist.isActive)")
                }
                let field = CGPoint(x: searchAssist.fieldFrame.midX, y: searchAssist.fieldFrame.midY)
                await click(field, "the field")
                await click(field, "the field again")
                await click(field, "the field a third time")
                await click(CGPoint(x: content.bounds.midX, y: content.bounds.height - 40), "the page")
            }
        }
        // `-VelvetHistoryTest YES`: History → a video → a channel, then Back, Back, Forward,
        // logging the page after each step.
        if UserDefaults.standard.bool(forKey: "VelvetHistoryTest") {
            Task {
                func describe(_ r: Route) -> String {
                    switch r {
                    case let .destination(d, p): "\(d.rawValue)\(p.map { "/\($0.title)" } ?? "")"
                    case let .search(q): "search \(q)"
                    case let .channel(id): "channel \(id)"
                    case let .video(v): "video \(v.id)"
                    }
                }
                let steps: [(String, () -> Void)] = [
                    ("History", { self.navigate(to: .history) }),
                    ("video", { self.open(Video(id: "Jgk7Y1TJX5U", title: "Test")) }),
                    ("channel", { self.openChannel("UCXuqSBlHAE6Xw-yeJA0Tunw") }),
                    ("Back", { self.goBack() }),
                    ("Back", { self.goBack() }),
                    ("Forward", { self.goForward() }),
                ]
                try? await Task.sleep(for: .seconds(5))
                for (name, step) in steps {
                    step()
                    try? await Task.sleep(for: .seconds(2))
                    log.info("Test: after \(name, privacy: .public): \(describe(self.currentRoute), privacy: .public), back \(self.canGoBack), forward \(self.canGoForward), PiP \(self.pip.isActive)")
                }
            }
        }
        // `-VelvetAccountTest YES`: open the account panel at 6 s.
        if UserDefaults.standard.bool(forKey: "VelvetAccountTest") {
            Task { try? await Task.sleep(for: .seconds(6)); showingAccount = true }
        }
        // `-VelvetPlaylistTest YES`: open your first playlist (after Watch Later) once they've loaded.
        if UserDefaults.standard.bool(forKey: "VelvetPlaylistTest") {
            Task {
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let p = playlistsModel?.playlists.first(where: { $0.id != "WL" }) {
                        log.info("Test: opening playlist \(p.title, privacy: .public)")
                        open(p)
                        // `-VelvetPlaylistPlay YES`: then play its second video, as a click would.
                        if UserDefaults.standard.bool(forKey: "VelvetPlaylistPlay") {
                            let feed = SectionedFeedModel(browseId: p.browseId, client: client)
                            await feed.loadIfNeeded()
                            let videos = feed.sections.flatMap(\.videos)
                            if videos.count > 1 {
                                play(videos[1], inPlaylist: videos, title: p.title)
                                log.info("Test: playing \(videos[1].id, privacy: .public) of \(videos.count); queue \(self.queue.items.count) upcoming, \(self.queue.played.count) played, from \(self.queue.source ?? "nil", privacy: .public), next \(self.queue.items.first?.id ?? "-", privacy: .public) (playlist's third: \(videos.count > 2 ? videos[2].id : "-", privacy: .public))")
                            }
                        }
                        return
                    }
                }
            }
        }
        // `-VelvetWindowFullscreenTest YES`: macOS fullscreen (not the player's) from 6 s to 12 s.
        if UserDefaults.standard.bool(forKey: "VelvetWindowFullscreenTest") {
            Task {
                try? await Task.sleep(for: .seconds(6)); mainWindow?.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(3))
                // What a click on the top bar's search field would reach.
                if let frame = mainWindow?.contentView?.superview {
                    let point = NSPoint(x: frame.bounds.midX, y: frame.bounds.maxY - 26)
                    log.info("Test: top bar click reaches \(String(describing: frame.hitTest(point).map { type(of: $0) }), privacy: .public)")
                }
                try? await Task.sleep(for: .seconds(3)); mainWindow?.toggleFullScreen(nil)
            }
        }
        // `-VelvetShort <id>`: open that Short in the Shorts player.
        if let id = UserDefaults.standard.string(forKey: "VelvetShort"), !id.isEmpty {
            open(Video(id: id, title: "Short \(id)", kind: .short))
            // `-VelvetShortsSwipeTest YES`: next Short at 8s, back at 14s.
            if UserDefaults.standard.bool(forKey: "VelvetShortsSwipeTest") {
                Task {
                    try? await Task.sleep(for: .seconds(8)); log.info("Test: next Short"); shortsOverlay?.go(1)
                    try? await Task.sleep(for: .seconds(6)); log.info("Test: previous Short"); shortsOverlay?.go(-1)
                }
            }
        }
        // `-VelvetMarkReadTest YES`: mark the newest unread notification read, then reload and check.
        if UserDefaults.standard.bool(forKey: "VelvetMarkReadTest") {
            Task {
                do {
                    let page = NotificationParser.inbox(from: try await client.notificationMenu())
                    guard let n = page.items.first(where: { !$0.isRead && $0.readToken != nil }) else { log.info("Test: nothing unread"); return }
                    log.info("Test: marking \(n.id, privacy: .public) read: \(n.message.prefix(40), privacy: .public)")
                    try await client.recordNotificationInteraction(n.readToken!)
                    try? await Task.sleep(for: .seconds(2))
                    let again = NotificationParser.inbox(from: try await client.notificationMenu())
                    log.info("Test: after reload read=\(again.items.first { $0.id == n.id }?.isRead.description ?? "missing", privacy: .public)")
                } catch {
                    log.error("Test: failed \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // `-VelvetInboxTest YES`: open the notifications popover at 6s.
        if UserDefaults.standard.bool(forKey: "VelvetInboxTest") {
            Task { try? await Task.sleep(for: .seconds(6)); showingInbox = true }
        }
        // `-VelvetQueue id1,id2`: start with these videos queued.
        for id in (UserDefaults.standard.string(forKey: "VelvetQueue") ?? "").split(separator: ",") {
            queue.add(Video(id: String(id), title: "Queued \(id)"))
        }
        // `-VelvetMinimizeTest YES` (with -VelvetPlay): what the I key does, at 8s.
        if UserDefaults.standard.bool(forKey: "VelvetMinimizeTest") {
            Task {
                try? await Task.sleep(for: .seconds(8))
                log.info("Test: I key (leave page into PiP)")
                leaveWatchPage(forcePictureInPicture: true)
                log.info("Test: page hidden=\(self.watchPageHidden), PiP active=\(self.pip.isActive)")
            }
        }
        // `-VelvetFrameMonitor YES`: log frame regularity every 2 s while you scroll by hand.
        if UserDefaults.standard.bool(forKey: "VelvetFrameMonitor") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let window = mainWindow { FrameMonitor.start(in: window) }
            }
        }
        // `-VelvetScrollPerfTest YES`: scroll like a trackpad at 12 s and log frame timing.
        if UserDefaults.standard.bool(forKey: "VelvetScrollPerfTest") {
            Self.testWatchCounts = { [weak self] in
                guard let page = self?.watching?.page else { return "no watch page" }
                return "\(page.comments.count) comments, \(page.related.count) related"
            }
            Task {
                try? await Task.sleep(for: .seconds(12))
                guard let window = mainWindow else { return }
                ScrollPerfTest.start(in: window, label: watching != nil ? "watch page" : "home")
            }
        }
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
                // `-VelvetScrollY <points>` picks the depth (layout checks further down the page).
                let y = UserDefaults.standard.double(forKey: "VelvetScrollY")
                try? await Task.sleep(for: .seconds(9)); scroll(to: y > 0 ? y : 900)
                // What a click on the search field would reach (the player under it must not).
                try? await Task.sleep(for: .seconds(1))
                if let content = mainWindow?.contentView {
                    let field = searchAssist.fieldFrame
                    let point = NSPoint(x: field.midX, y: content.bounds.height - field.midY)
                    let hit = content.hitTest(point)
                    log.info("Test: hit test at the search field: \(hit.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public), player slot top \(Int(self.playerSlot.minY)), field \(Int(field.minY))–\(Int(field.maxY))")
                    // A real click there (the window must be frontmost): it must open search,
                    // not pause the video.
                    let pausedBefore = watching?.player.isPaused ?? true
                    if let window = mainWindow {
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                NSApp.postEvent(e, atStart: false)
                            }
                        }
                    }
                    try? await Task.sleep(for: .seconds(1))
                    log.info("Test: after clicking the search field: video paused \(pausedBefore) → \(self.watching?.player.isPaused ?? true), search active \(self.searchAssist.isActive)")
                }
                try? await Task.sleep(for: .seconds(5)); scroll(to: 0)
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
                    if UserDefaults.standard.bool(forKey: "VelvetPiPSkipTest") {
                        let before = watching?.player.position ?? 0
                        pip.debugSimulateSkip(30)
                        try? await Task.sleep(for: .seconds(1.5))
                        log.info("PiP skip test: position \(Int(before), privacy: .public)s → \(Int(self.watching?.player.position ?? 0), privacy: .public)s")
                    }
                    try? await Task.sleep(for: .seconds(1))
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
                isSidebarCollapsed = false
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    togglePlayerFullscreen()
                    try? await Task.sleep(for: .seconds(6))
                    togglePlayerFullscreen()
                }
            }
            // `-VelvetWindowWidth N`: resize the window to N points wide (layout checks).
            let width = UserDefaults.standard.double(forKey: "VelvetWindowWidth")
            if width > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                        if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil); try? await Task.sleep(for: .seconds(2)) }
                        w.setFrame(NSRect(x: 60, y: 60, width: width, height: 760), display: true, animate: false)
                    }
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
        inbox.stopPolling()
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
        // Read the search history now, so the search box has it the first time it's opened.
        searchAssist.prefetchHistory()
        // Not awaited: its retries mustn't hold up the rest of sign-in.
        Task { await refreshAccount() }
        inbox.startPolling()
        if settings.uploadAlerts { await alerts.requestPermission() }
    }

    /// Turning upload alerts on: ask macOS for permission and check right away.
    func uploadAlertsChanged() {
        guard authState == .signedIn else { return }
        Task {
            if settings.uploadAlerts { await alerts.requestPermission() }
            await inbox.poll()
        }
    }

    /// The name and picture in the top bar. YouTube sometimes answers this one request with
    /// HTTP 500 while everything else works, which left the bar blank until the next launch,
    /// so a failure is retried a few times.
    func refreshAccount() async {
        guard !refreshingAccount else { return }
        refreshingAccount = true
        defer { refreshingAccount = false }
        for (attempt, delay) in [0, 2, 5, 15].enumerated() {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard authState == .signedIn else { return }
            do {
                let json = try await client.accountMenu()
                account = Account(accountMenu: json)
                if account == nil {
                    // No account header means the cookies no longer authenticate.
                    log.warning("Account menu had no active account; session may have expired")
                }
                return
            } catch {
                log.error("Account fetch failed (try \(attempt + 1)): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    @ObservationIgnored private var refreshingAccount = false

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
