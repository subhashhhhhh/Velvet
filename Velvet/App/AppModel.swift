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

    var destination: Destination? = .home
    var searchText = ""
    /// The submitted query; non-nil shows search results instead of the destination.
    var activeSearch: String?

    init() {
        #if DEBUG
        // `-VelvetSearch "query"` opens straight into results; handy for testing.
        if let q = UserDefaults.standard.string(forKey: "VelvetSearch"), !q.isEmpty {
            searchText = q
            activeSearch = q
        }
        #endif
    }

    func submitSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearch = q.isEmpty ? nil : q
    }

    /// Opens a video. Playback arrives with the mpv player; for now this just records it.
    var openedVideo: Video?
    func open(_ video: Video) {
        openedVideo = video
    }

    func navigate(to destination: Destination) {
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
    private(set) var authRevision = 0

    /// Restores a saved session at launch.
    func start() async {
        guard authState == .unknown else { return }
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

    private let log = Logger(subsystem: "com.subhash.Velvet", category: "App")
}
