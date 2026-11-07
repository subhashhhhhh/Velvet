import SwiftUI

/// Grid of videos with an optional Shorts shelf, infinite scroll and states.
struct FeedView: View {
    let feed: FeedModel
    /// Set false for surfaces that should never show the Shorts shelf.
    var allowsShortsShelf = true
    var onOpen: (Video) -> Void = { _ in }

    @Environment(AppModel.self) private var app
    @State private var gridWidth: CGFloat = 0

    private var columnCount: Int {
        Self.columns(for: gridWidth - Self.padding * 2, minCard: prefs.cardSize.minWidth)
    }

    private nonisolated static let spacing: CGFloat = 14
    private nonisolated static let padding: CGFloat = 20

    private var prefs: Preferences { app.settings }

    /// Videos after applying the "hide watched" preference.
    private var visible: [Video] {
        prefs.hideWatched ? feed.videos.filter { ($0.watchedFraction ?? 0) < 0.9 } : feed.videos
    }

    var body: some View {
        Group {
            if feed.videos.isEmpty && feed.shorts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        let videos = visible
                        let split = min(videos.count, columnCount * prefs.shortsAfterRows)
                        grid(videos[..<split], all: videos)
                        if allowsShortsShelf && prefs.showShortsShelf && !feed.shorts.isEmpty {
                            ShortsShelf(shorts: feed.shorts, onOpen: onOpen)
                        }
                        grid(videos[split...], all: videos)
                        footer
                    }
                    .padding(Self.padding)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            }
        }
        .task { await feed.loadIfNeeded() }
    }

    /// Explicit column count (instead of `.adaptive`) so "after N rows" is exact.
    private nonisolated static func columns(for width: CGFloat, minCard: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minCard + spacing)))
    }

    private func grid(_ videos: ArraySlice<Video>, all: [Video]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: columnCount),
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(videos) { video in
                Button { onOpen(video) } label: { VideoCard(video: video) }
                    .buttonStyle(.plain)
                    .onAppear {
                        // Fetch the next page when one of the last few visible cards appears.
                        if all.suffix(8).contains(where: { $0.id == video.id }) {
                            Task { await feed.loadMore() }
                        }
                    }
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
