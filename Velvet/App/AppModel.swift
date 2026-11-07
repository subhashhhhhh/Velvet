import SwiftUI

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

    func submitSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearch = q.isEmpty ? nil : q
    }

    func navigate(to destination: Destination) {
        activeSearch = nil
        self.destination = destination
    }
}
