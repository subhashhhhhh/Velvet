import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            detail
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search YouTube")
        .onSubmit(of: .search) { app.submitSearch() }
    }

    @ViewBuilder
    private var detail: some View {
        if let query = app.activeSearch {
            PlaceholderView(title: "Search", symbol: "magnifyingglass", message: "Results for “\(query)” land in the next step.")
        } else {
            let d = app.destination ?? .home
            PlaceholderView(title: d.title, symbol: d.symbol, message: "Coming soon.")
        }
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
    }

    private func row(_ d: Destination) -> some View {
        Label(d.title, systemImage: d.symbol).tag(d)
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
