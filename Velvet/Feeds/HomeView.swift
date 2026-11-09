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
                    FeedView(feed: feed, onOpen: { app.open($0) })
                        .id(app.authRevision)
                }
            }
        }
        .navigationTitle("Home")
        .topBarActions(app.authState == .signedIn
                       ? [TopBarAction(id: "Refresh", symbol: "arrow.clockwise", shortcut: "r") { Task { await app.homeFeed?.reload() } }]
                       : [])
    }
}

/// Latest uploads from the channels you're subscribed to.
struct SubscriptionsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.authState {
            case .unknown:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SignInRequiredView(title: "Subscriptions", symbol: Destination.subscriptions.symbol,
                                   message: "Sign in to see new videos from the channels you subscribe to.")
            case .signedIn:
                if let feed = app.subscriptionsFeed {
                    FeedView(feed: feed, onOpen: { app.open($0) })
                        .id(app.authRevision)
                }
            }
        }
        .navigationTitle("Subscriptions")
        .topBarTitle("Subscriptions")
        .topBarActions(app.authState == .signedIn
                       ? [TopBarAction(id: "Refresh", symbol: "arrow.clockwise", shortcut: "r") { Task { await app.subscriptionsFeed?.reload() } }]
                       : [])
    }
}
