import SwiftUI

/// Grid of videos with an optional Shorts shelf, infinite scroll and states.
struct FeedView: View {
    let feed: FeedModel
    var showsShorts = true
    /// Rows of regular videos shown before the Shorts shelf.
    var shortsAfterRows = 3
    var onOpen: (Video) -> Void = { _ in }

    private nonisolated static let minCardWidth: CGFloat = 260
    private nonisolated static let spacing: CGFloat = 14
    private nonisolated static let padding: CGFloat = 20

    @State private var columnCount = 3

    var body: some View {
        Group {
            if feed.videos.isEmpty && feed.shorts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        let split = min(feed.videos.count, columnCount * shortsAfterRows)
                        grid(feed.videos[..<split])
                        if showsShorts && !feed.shorts.isEmpty {
                            ShortsShelf(shorts: feed.shorts, onOpen: onOpen)
                        }
                        grid(feed.videos[split...])
                        footer
                    }
                    .padding(Self.padding)
                }
                .onGeometryChange(for: Int.self) { geo in
                    Self.columns(for: geo.size.width - Self.padding * 2)
                } action: { columnCount = $0 }
            }
        }
        .task { await feed.loadIfNeeded() }
    }

    /// Explicit column count (instead of `.adaptive`) so "after N rows" is exact.
    private nonisolated static func columns(for width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minCardWidth + spacing)))
    }

    private func grid(_ videos: ArraySlice<Video>) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: columnCount),
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(videos) { video in
                Button { onOpen(video) } label: { VideoCard(video: video) }
                    .buttonStyle(.plain)
                    .onAppear { feed.itemAppeared(video) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if feed.isLoading || !feed.hasLoaded {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = feed.error {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await feed.reload() } }
            }
        } else {
            ContentUnavailableView("Nothing Here", systemImage: "tray")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if feed.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let error = feed.error {
            HStack {
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { Task { await feed.loadMore() } }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct ShortsShelf: View {
    let shorts: [Video]
    var onOpen: (Video) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shorts", systemImage: "play.rectangle.on.rectangle")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(shorts) { short in
                        Button { onOpen(short) } label: { ShortCard(video: short) }
                            .buttonStyle(.plain)
                            .frame(width: 150)
                    }
                }
            }
        }
    }
}
