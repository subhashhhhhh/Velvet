import SwiftUI

enum SidebarMetrics {
    /// Column widths, the panel's inset from the window edge included.
    static let fullWidth: CGFloat = 248
    static let railWidth: CGFloat = 88
    static let inset: CGFloat = 8
    /// Room at the top of the panel for the window's close/minimize/zoom buttons.
    static let windowButtons: CGFloat = 44
    static let cornerRadius: CGFloat = 16
}

/// Velvet's own sidebar: a floating panel with the destinations, your playlists and what's
/// playing. Collapsed, it becomes a narrow rail of icons with short labels.
struct Sidebar: View {
    @Environment(AppModel.self) private var app
    @Namespace private var selection

    var body: some View {
        let collapsed = app.isSidebarCollapsed
        ZStack(alignment: .topLeading) {
            if collapsed {
                SidebarRail(selection: selection)
                    .transition(.opacity)
            } else {
                SidebarList(selection: selection)
                    .transition(.opacity)
            }
        }
        .frame(width: (collapsed ? SidebarMetrics.railWidth : SidebarMetrics.fullWidth) - SidebarMetrics.inset)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarPanel())
        .clipShape(RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius, style: .continuous))
        .padding([.leading, .vertical], SidebarMetrics.inset)
        .opacity(app.playerFullscreen ? 0 : 1)
        .task(id: app.playlistsModel.map(ObjectIdentifier.init)) {
            // Your playlists, listed under Library. Let launch's own requests go first.
            try? await Task.sleep(for: .seconds(2))
            await app.playlistsModel?.loadIfNeeded()
        }
    }
}

private struct SidebarPanel: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius, style: .continuous)
        shape
            .fill(.primary.opacity(0.045))
            .overlay(shape.strokeBorder(.primary.opacity(0.07)))
    }
}

/// What the sidebar highlights: nothing while a video, Short, channel or search covers the
/// page, so clicking the current destination (e.g. Home under a video) still navigates.
private extension AppModel {
    var sidebarSelection: Destination? {
        activeSearch == nil && !isShowingWatchPage && shortsOverlay == nil && channel == nil ? destination : nil
    }

    func isSelected(_ d: Destination) -> Bool {
        sidebarSelection == d && !(d == .playlists && openPlaylist != nil)
    }

    func isSelected(_ p: PlaylistSummary) -> Bool {
        sidebarSelection == .playlists && openPlaylist?.id == p.id
    }

    /// Changes whenever the highlight moves, to animate it.
    var selectionKey: String {
        "\(sidebarSelection?.rawValue ?? "-")|\(openPlaylist?.id ?? "-")"
    }

    /// A video carrying on in PiP after you browsed away from its page.
    var pipSession: PlayerSession? { watchPageHidden ? watching : nil }
}

// MARK: - Full width

private struct SidebarList: View {
    let selection: Namespace.ID
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: SidebarMetrics.windowButtons)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([Destination.home, .shorts, .live]) { row($0) }
                    header("Library")
                    ForEach([Destination.history, .watchLater, .playlists]) { row($0) }
                    row(.queue, badge: app.queue.items.count)
                    // Watch Later is already above.
                    if let playlists = app.playlistsModel?.playlists.filter({ $0.id != "WL" }), !playlists.isEmpty {
                        header("Playlists")
                        ForEach(playlists.prefix(12)) { p in
                            SidebarRow(title: p.title, isSelected: app.isSelected(p), selection: selection, action: { app.open(p) }) {
                                RemoteImage(url: p.thumbnail)
                                    .frame(width: 22, height: 22)
                                    .background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .animation(.smooth(duration: 0.28), value: app.selectionKey)
            if let session = app.pipSession {
                NowPlayingCard(session: session)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: app.pipSession?.id)
    }

    private func row(_ d: Destination, badge: Int = 0) -> some View {
        let selected = app.isSelected(d)
        return SidebarRow(title: d.title, badge: badge, isSelected: selected, selection: selection,
                          action: { app.navigate(to: d) }) {
            Image(systemName: d.symbol)
                .symbolVariant(selected ? .fill : .none)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 22)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }
}

private struct SidebarRow<Icon: View>: View {
    let title: String
    var badge = 0
    let isSelected: Bool
    let selection: Namespace.ID
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                Text(title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(isSelected ? 1 : 0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(0.1))
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Rail

private struct SidebarRail: View {
    let selection: Namespace.ID
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 2) {
            Color.clear.frame(height: SidebarMetrics.windowButtons)
            ForEach([Destination.home, .shorts, .live]) { item($0) }
            Divider().frame(width: 32).padding(.vertical, 6)
            ForEach([Destination.history, .watchLater, .playlists]) { item($0) }
            item(.queue, badge: app.queue.items.count)
            Spacer(minLength: 0)
            if let session = app.pipSession {
                NowPlayingThumbnail(session: session)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.28), value: app.selectionKey)
        .animation(.smooth(duration: 0.3), value: app.pipSession?.id)
    }

    private func item(_ d: Destination, badge: Int = 0) -> some View {
        RailItem(destination: d, badge: badge, isSelected: app.isSelected(d), selection: selection) {
            app.navigate(to: d)
        }
    }
}

private struct RailItem: View {
    let destination: Destination
    var badge = 0
    let isSelected: Bool
    let selection: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: destination.symbol)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(height: 20)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3.5)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(.red, in: Capsule())
                                .offset(x: 10, y: -6)
                        }
                    }
                Text(destination.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 68, height: 52)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.primary.opacity(0.1))
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(destination.title)
    }
}

// MARK: - Now playing

/// The video playing in PiP after you left its page: click to go back to it.
private struct NowPlayingCard: View {
    let session: PlayerSession
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                RemoteImage(url: session.video.thumbnail(minWidth: 160))
                    .frame(width: 64, height: 36)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.page.details?.title ?? session.video.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    if let channel = session.video.channelName {
                        Text(channel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                PlaybackProgress(player: session.player)
                PlayPauseButton(player: session.player)
                Button { app.closePlayer() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(ChromeButtonStyle(size: 22))
                .help("Close")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(hovering ? 0.09 : 0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { app.showWatchPage() }
        .onHover { hovering = $0 }
        .help("Back to the video")
    }
}

private struct NowPlayingThumbnail: View {
    let session: PlayerSession
    @Environment(AppModel.self) private var app

    var body: some View {
        Button { app.showWatchPage() } label: {
            VStack(spacing: 5) {
                RemoteImage(url: session.video.thumbnail(minWidth: 160))
                    .frame(width: 64, height: 36)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                PlaybackProgress(player: session.player).frame(width: 64)
            }
        }
        .buttonStyle(.plain)
        .help(session.page.details?.title ?? session.video.title)
    }
}

/// Separate views so only they redraw as the position ticks.
private struct PlaybackProgress: View {
    let player: MPVPlayer

    var body: some View {
        let fraction = player.duration > 0 ? min(1, max(0, player.position / player.duration)) : 0
        Capsule()
            .fill(.primary.opacity(0.12))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(.red).frame(width: geo.size.width * fraction)
                }
            }
    }
}

private struct PlayPauseButton: View {
    let player: MPVPlayer

    var body: some View {
        Button { player.togglePause() } label: {
            Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.system(size: 11))
        }
        .buttonStyle(ChromeButtonStyle(size: 22))
        .help(player.isPaused ? "Play" : "Pause")
    }
}
