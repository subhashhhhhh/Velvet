import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.authState {
            case .unknown:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                ContentUnavailableView {
                    Label("Your Recommendations", systemImage: "house")
                } description: {
                    Text("YouTube only shows a home feed to signed-in accounts.")
                } actions: {
                    Button("Sign In with Google") { app.showingSignIn = true }
                        .buttonStyle(.borderedProminent)
                }
            case .signedIn:
                if let feed = app.homeFeed {
                    FeedView(feed: feed, onOpen: app.open)
                        .id(app.authRevision)
                }
            }
        }
        .navigationTitle("Home")
        .toolbar {
            if app.authState == .signedIn {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await app.homeFeed?.reload() }
                }
                .keyboardShortcut("r")
            }
        }
    }
}
