import SwiftUI

/// Grid of videos with an optional Shorts shelf, infinite scroll and states.
struct FeedView: View {
    let feed: FeedModel
    /// Set false for surfaces that should never show the Shorts shelf.
    var allowsShortsShelf = true
    var onOpen: (Video) -> Void = { _ in }

    @Environment(AppModel.self) private var app
    @State private var layout = GridLayout()
    @State private var tracker = GridTracker()
    @State private var scroll = ScrollPosition()

    private var columnCount: Int { VideoGrid.columns(layout, prefs: prefs) }

    private var prefs: Preferences { app.settings }

    /// Videos after applying the "hide watched" / "hide members-only" preferences.
    private var visible: [Video] {
        let dismissed = app.dismissedVideos
        return feed.videos.filter { !dismissed.contains($0.id) && (!(prefs.hideWatched || prefs.hideMembersOnly) || prefs.shows($0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !feed.chips.isEmpty {
                ChipBar(chips: feed.chips, selected: feed.selectedChip) { chip in
                    Task { await feed.select(chip) }
                }
            }
            content
        }
        .task { await feed.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if feed.videos.isEmpty && feed.shorts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        let videos = visible
                        let split = min(videos.count, columnCount * prefs.shortsAfterRows)
                        let _ = tracker.split = split
                        grid(videos[..<split], all: videos, index: 0)
                        if allowsShortsShelf && prefs.showShortsShelf && !feed.shorts.isEmpty {
                            ShortsShelf(shorts: feed.shorts, onOpen: onOpen)
                        }
                        grid(videos[split...], all: videos, index: 1)
                        footer
                    }
                    .padding(VideoGrid.padding)
                    // Under the chips, leave the same 26pt gap as between thumbnails
                    // (chip bar's 10pt + this + the card inset).
                    .padding(.top, feed.chips.isEmpty ? 0 : 10 - VideoGrid.padding)
                    .coordinateSpace(.named(GridTracker.space))
                    .gridWidth(layout)
                }
                .trackedGridScroll($scroll, tracker: tracker)
                .sidebarStableLayout($layout) { tracker.keepReadingPosition(order: visible, scroll: $scroll) }
                .id(feed.selectedChip?.id) // a new topic starts at the top
            }
        }
    }

    // Explicit column count (instead of `.adaptive`) so "after N rows" is exact.
    private func grid(_ videos: ArraySlice<Video>, all: [Video], index: Int) -> some View {
        LazyVGrid(columns: VideoGrid.gridItems(columnCount), alignment: .leading, spacing: 18) {
            ForEach(videos) { video in
                Button { onOpen(video) } label: { VideoCard(video: video) }
                    .buttonStyle(.plain)
                    .trackedInGrid(video.id, grid: index, by: tracker)
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

/// YouTube's topic chips: "All", "Music", "Formula 1", … scrolled sideways.
struct ChipBar: View {
    let chips: [FeedChip]
    let selected: FeedChip?
    var onSelect: (FeedChip?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    let isOn = chip.token == nil ? selected == nil : chip == selected
                    Button { onSelect(chip) } label: {
                        Text(chip.title)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(isOn ? Color(nsColor: .windowBackgroundColor) : .primary)
                            .background(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            // Chips line up with the thumbnails below, not with the cards' hover highlight.
            .padding(.horizontal, VideoGrid.contentInset)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled(false)
    }
}

struct ShortsShelf: View {
    let shorts: [Video]
    /// Narrower in the watch page's side column, so about three cards fit.
    var cardWidth: CGFloat = 150
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
                            .frame(width: cardWidth)
                    }
                }
            }
        }
    }
}
