import SwiftUI

/// Grid of videos with an optional Shorts shelf, infinite scroll and states.
struct FeedView: View {
    let feed: FeedModel
    var showsShorts = true
    var onOpen: (Video) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 14, alignment: .top)]

    var body: some View {
        Group {
            if feed.videos.isEmpty && feed.shorts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if showsShorts && !feed.shorts.isEmpty {
                            ShortsShelf(shorts: feed.shorts, onOpen: onOpen)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(feed.videos) { video in
                                Button { onOpen(video) } label: { VideoCard(video: video) }
                                    .buttonStyle(.plain)
                                    .onAppear { feed.itemAppeared(video) }
                            }
                        }
                        footer
                    }
                    .padding(20)
                }
            }
        }
        .task { await feed.loadIfNeeded() }
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
