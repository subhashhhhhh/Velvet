import SwiftUI
import OSLog

/// The width a video grid lays out at, and which "videos per row" setting applies.
struct GridLayout: Equatable {
    var width: CGFloat = 0
    var sidebarCollapsed = false
}

/// Shared sizing for the video grids (Home, search, History, Watch Later, channels).
enum VideoGrid {
    static let spacing: CGFloat = 14
    static let padding: CGFloat = 20
    /// A card's inset around its thumbnail (room for the hover highlight). Thumbnails therefore
    /// start `padding + cardInset` from the edge and sit `spacing + 2 × cardInset` apart (26pt).
    static let cardInset: CGFloat = 6
    /// Where thumbnails start; things above the grid (the topic chips) line up with it.
    static var contentInset: CGFloat { padding + cardInset }
    /// Below this a card's title and metadata stop being readable, so a narrow window
    /// shows fewer columns than the setting asks for.
    static let minCardWidth: CGFloat = 170

    /// Columns for a grid laid out at `layout` (the grid's full width, padding included).
    static func columns(_ layout: GridLayout, prefs: Preferences) -> Int {
        let preferred = layout.sidebarCollapsed ? prefs.videosPerRowSidebarHidden : prefs.videosPerRow
        guard layout.width > 0 else { return preferred }
        let fit = Int((layout.width - padding * 2 + spacing) / (minCardWidth + spacing))
        return max(1, min(preferred, fit))
    }

    static func gridItems(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
    }
}

/// Where the grid's cards are, for keeping the reading position while the grid reflows.
/// A plain class: updating it must not re-render the grid.
final class GridTracker {
    /// Cards mostly on screen.
    var visible = Set<String>()
    /// Top of each card laid out so far, in the grid's content (changes only when the layout
    /// does), keyed by grid and id. A few hundred numbers at most, so stale ones are left.
    var tops: [String: CGFloat] = [:]
    /// The scroll view's content offset.
    var offset: CGFloat = 0
    /// Home splits its videos into a grid above the Shorts shelf and one below; cards from
    /// this index on are in the second. The split moves with the column count, and a card
    /// that changes grid is rebuilt, so its position is tracked per grid.
    var split = Int.max

    static func key(_ id: String, grid: Int) -> String { "\(grid)|\(id)" }

    nonisolated static let space = "VideoGridContent"

    /// Run when the sidebar starts moving: returns what to do once the new layout is in, to
    /// put the first visible card back where it was on screen.
    func keepReadingPosition(order: [Video], scroll: Binding<ScrollPosition>) -> (() async -> Void)? {
        guard let index = order.firstIndex(where: { visible.contains($0.id) }), index > 0 else { return nil }
        let id = order[index].id
        let oldKey = Self.key(id, grid: index < split ? 0 : 1)
        guard let oldTop = tops[oldKey] else { return nil }
        let oldOffset = offset
        return { [self] in
            // The cards report their new places a frame or two after the layout changes
            // (and `split` is updated by then).
            let newKey = Self.key(id, grid: index < split ? 0 : 1)
            for _ in 0..<25 where tops[newKey] == nil || (newKey == oldKey && tops[newKey] == oldTop) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let newTop = tops[newKey] else { return }
            withAnimation(AppModel.sidebarAnimation) {
                scroll.wrappedValue.scrollTo(y: max(0, oldOffset + newTop - oldTop))
            }
        }
    }
}

extension View {
    /// Records where this grid card is and whether it's mostly on screen.
    func trackedInGrid(_ id: String, grid: Int = 0, by tracker: GridTracker) -> some View {
        onScrollVisibilityChange(threshold: 0.5) { visible in
            if visible { tracker.visible.insert(id) } else { tracker.visible.remove(id) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(GridTracker.space)).minY } action: {
            tracker.tops[GridTracker.key(id, grid: grid)] = $0
        }
        // A lazy grid discards far-off cards without reporting them as hidden. Positions stay:
        // a card moving between the grids above and below the Shorts shelf is rebuilt, and the
        // old copy can disappear after the new one has reported where it is.
        .onDisappear { tracker.visible.remove(id) }
    }

    /// The grid's scroll view: follows `position` and reports its offset to `tracker`.
    func trackedGridScroll(_ position: Binding<ScrollPosition>, tracker: GridTracker) -> some View {
        scrollPosition(position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { tracker.offset = $1 }
    }
}

/// Keeps a grid steady while the sidebar slides in or out.
///
/// The split view gives the page its new width in one step while the sidebar is still
/// sliding, so the grid used to snap to its new columns and card sizes mid-slide. Instead,
/// the grid animates to the layout it will have once the sidebar finishes, in step with the
/// slide, and keeps the first visible card at the top. During the slide the grid may be wider
/// than the page for a moment; the scroll view clips it.
///
/// Which signal arrives first varies: showing the sidebar reports the visibility change
/// first, hiding it reports the new width ~50 ms before the visibility. Either one starts the
/// transition; the other then only confirms it. After the slide, the real width and sidebar
/// state are applied (normally a no-op).
struct SidebarStableLayout: ViewModifier {
    @Binding var layout: GridLayout
    /// Called as the reflow starts; returns what to run once the new layout is in.
    var prepareReflow: () -> (() async -> Void)? = { nil }

    @Environment(AppModel.self) private var app
    @State private var liveWidth: CGFloat = 0
    @State private var settling: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.subhash.Velvet", category: "Layout")

    func body(content: Content) -> some View {
        content
            // Measure the space the page offers, not the (possibly wider, mid-slide) grid.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let delta = width - liveWidth
                liveWidth = width
                guard settling == nil else { return }
                // A jump of about the sidebar's width in one step is the sidebar, not a resize.
                if layout.width > 0, abs(abs(delta) - app.sidebarWidth) < app.sidebarWidth * 0.25 {
                    begin(collapsed: delta > 0, target: width)
                } else {
                    layout.width = width
                }
            }
            .onAppear { layout.sidebarCollapsed = app.isSidebarCollapsed }
            .onChange(of: app.isSidebarCollapsed) { _, collapsed in
                if settling != nil && layout.sidebarCollapsed == collapsed { return } // the width got here first
                guard layout.width > 0 else { layout.sidebarCollapsed = collapsed; return }
                begin(collapsed: collapsed, target: max(0, layout.width + (collapsed ? app.sidebarWidth : -app.sidebarWidth)))
            }
    }

    private func begin(collapsed: Bool, target: CGFloat) {
        let afterLayout = prepareReflow()
        #if DEBUG
        Self.log.debug("Sidebar \(collapsed ? "hiding" : "showing", privacy: .public): \(Int(layout.width))pt → \(Int(target))pt, keep position: \(afterLayout != nil)")
        #endif
        withAnimation(AppModel.sidebarAnimation) {
            layout = GridLayout(width: target, sidebarCollapsed: collapsed)
        }
        if let afterLayout { Task { await afterLayout() } }
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: .milliseconds(UserDefaults.standard.bool(forKey: "VelvetSlowSidebar") ? 3500 : 450))
            guard !Task.isCancelled else { return }
            settling = nil
            #if DEBUG
            Self.log.debug("Sidebar settled: predicted \(Int(layout.width))pt, actual \(Int(liveWidth))pt")
            #endif
            if layout.width != liveWidth || layout.sidebarCollapsed != app.isSidebarCollapsed {
                withAnimation(AppModel.sidebarAnimation) {
                    layout = GridLayout(width: liveWidth, sidebarCollapsed: app.isSidebarCollapsed)
                }
            }
        }
    }
}

extension View {
    /// Lays the grid out at `layout.width` (leading-aligned) rather than the live width.
    func gridWidth(_ layout: GridLayout) -> some View {
        frame(width: layout.width > 0 ? layout.width : nil, alignment: .leading)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    func sidebarStableLayout(_ layout: Binding<GridLayout>,
                             prepareReflow: @escaping () -> (() async -> Void)? = { nil }) -> some View {
        modifier(SidebarStableLayout(layout: layout, prepareReflow: prepareReflow))
    }
}
