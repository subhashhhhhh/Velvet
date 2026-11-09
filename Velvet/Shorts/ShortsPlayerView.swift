import SwiftUI
import AppKit

/// Vertical Shorts player: video in the middle, actions beside it, and description/comments
/// in a panel to the right. Scroll, ↑/↓ or the chevrons move between Shorts.
struct ShortsPlayerView: View {
    let controller: ShortsController
    var showsBack: Bool
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    private static let panelWidth: CGFloat = 400

    /// The video's shape (width ÷ height), 9:16 until mpv reports it. Shorts can be anything
    /// from 9:16 to square (a few older ones are landscape).
    private var aspect: CGFloat {
        if let held = controller.slideAspect { return min(max(held, 9 / 16), 16 / 9) }
        guard let size = controller.session?.player.videoSize, size.width > 0, size.height > 0 else { return 9 / 16 }
        return min(max(size.width / size.height, 9 / 16), 16 / 9)
    }

    /// Full height at the video's shape; narrower windows (or the comments panel) shrink it.
    private func cardSize(in container: CGSize) -> CGSize {
        var height = max(320, container.height - 40)
        // Room left beside the actions, the up/down buttons, spacing and the side panel.
        let maxWidth = container.width - 40 - 64 - 50 - 18 * 3
            - (controller.panel != .none ? Self.panelWidth + 18 : 0)
        var width = height * aspect
        if width > maxWidth, maxWidth > 100 {
            width = maxWidth
            height = width / aspect
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    var body: some View {
        GeometryReader { geo in
            let card = cardSize(in: geo.size)
            let (width, height) = (card.width, card.height)
            HStack(alignment: .center, spacing: 18) {
                Spacer(minLength: 0)
                ZStack {
                    if let session = controller.session {
                        ShortCardPlayer(session: session) { toggle(.description) }
                            .id(session.id)
                            // Swiping slides the next Short in from below (previous: from above).
                            .transition(.asymmetric(
                                insertion: .move(edge: controller.direction > 0 ? .bottom : .top),
                                removal: .move(edge: controller.direction > 0 ? .top : .bottom)))
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black)
                        statusView
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                // mpv's video layer ignores the rounded mask; a plain clip keeps a sliding
                // card's video inside the frame.
                .clipped()

                if let session = controller.session {
                    ShortActions(session: session, panel: controller.panel, toggle: toggle)
                        .frame(height: height, alignment: .bottom)
                }

                if controller.panel != .none, let session = controller.session {
                    ShortSidePanel(session: session, panel: controller.panel) { controller.panel = .none }
                        .frame(width: Self.panelWidth, height: height)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                navigation.frame(height: height)
            }
            .padding(.horizontal, 20)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(ScrollPager { delta in controller.go(delta) })
            // A Short that isn't 9:16 (square, 3:4) reshapes its card once mpv knows its size
            // (after a swipe's slide: the card keeps its shape while sliding).
            .animation(.smooth(duration: 0.25), value: aspect)
        }
        .animation(.easeOut(duration: 0.2), value: controller.panel)
        .navigationTitle("Shorts")
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .downArrow: controller.go(1)
            case .upArrow: controller.go(-1)
            case .space: controller.session?.player.togglePause()
            case .escape where controller.panel != .none: controller.panel = .none
            default:
                switch press.characters.lowercased() {
                case "m": controller.session?.player.toggleMute()
                case "c": toggle(.comments)
                default: return .ignored
                }
            }
            return .handled
        }
        .task { focused = true; await controller.start() }
        .onDisappear { controller.pause() }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "velvet-seek", let seconds = Double(url.host() ?? ""), let p = controller.session?.player {
                p.seek(to: seconds); p.play()
                return .handled
            }
            return .systemAction
        })
    }

    private func toggle(_ panel: ShortsController.Panel) {
        controller.panel = controller.panel == panel ? .none : panel
    }

    @ViewBuilder
    private var statusView: some View {
        if let error = controller.sequence.error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(error).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white).padding()
        } else {
            ProgressView().controlSize(.large).tint(.white)
        }
    }

    private var navigation: some View {
        VStack(spacing: 12) {
            Spacer()
            Button { controller.go(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!controller.sequence.canGoBack)
            Button { controller.go(1) } label: { Image(systemName: "chevron.down") }
                .disabled(controller.sequence.next == nil)
            Spacer()
        }
        .buttonStyle(CircleIconButtonStyle(size: 44))
    }
}

// MARK: - Player card

private struct ShortCardPlayer: View {
    let session: PlayerSession
    var onTitleTap: () -> Void
    @Environment(AppModel.self) private var app

    private var player: MPVPlayer { session.player }
    private var details: WatchDetails? { session.page.details }

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: player)
            if session.phase == .resolving || player.isLoading || player.isBuffering {
                ProgressView().controlSize(.large).tint(.white)
            }
            if case .failed(let message) = session.phase {
                VStack(spacing: 10) {
                    Text(message).multilineTextAlignment(.center)
                    Button("Try Again") { session.retry() }.buttonStyle(.prominentOverMedia)
                }
                .foregroundStyle(.white).padding()
            }
            if player.isPaused && session.phase == .ready && !player.isLoading {
                Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 8)
            }
            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                HStack(spacing: 8) {
                    RemoteImage(url: details?.channel?.avatar)
                        .frame(width: 30, height: 30).clipShape(Circle())
                    Text(details?.channel?.name ?? session.video.channelName ?? "")
                        .font(.subheadline.weight(.semibold))
                        .channelLink(details?.channel?.id ?? session.video.channelId)
                }
                Button(action: onTitleTap) {
                    Text(details?.title ?? session.video.title)
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
                .help("Show description")
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .padding(.bottom, 6)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 160)
            }
            VStack {
                Spacer()
                GeometryReader { g in
                    Rectangle().fill(.white.opacity(0.9))
                        .frame(width: player.duration > 0 ? g.size.width * min(1, player.position / player.duration) : 0)
                }
                .frame(height: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { player.togglePause() }
    }
}

// MARK: - Actions

private struct ShortActions: View {
    let session: PlayerSession
    @Environment(AppModel.self) private var app
    let panel: ShortsController.Panel
    var toggle: (ShortsController.Panel) -> Void

    private var page: WatchPageModel { session.page }

    var body: some View {
        VStack(spacing: 18) {
            ActionButton(symbol: page.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup",
                         label: page.displayedLikeCount ?? "Like") { page.toggleLike() }
            ActionButton(symbol: page.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                         label: "Dislike") { page.toggleDislike() }
            ActionButton(symbol: panel == .comments ? "text.bubble.fill" : "text.bubble",
                         label: "Comments") { toggle(.comments) }
            Menu {
                Button("Copy Link") { copy("https://www.youtube.com/shorts/\(session.video.id)") }
                Button("Open in Browser") { NSWorkspace.shared.open(URL(string: "https://www.youtube.com/shorts/\(session.video.id)")!) }
                Divider()
                Button(page.isInWatchLater ? "Remove from Watch Later" : "Save to Watch Later") { page.toggleWatchLater() }
            } label: {
                ActionLabel(symbol: "arrowshape.turn.up.right", label: "Share")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            Button {
                if let id = page.details?.channel?.id ?? session.video.channelId { app.openChannel(id) }
            } label: {
                RemoteImage(url: page.details?.channel?.avatar)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(page.details?.channel?.name ?? "Channel")
        }
        .alert("Couldn't Complete That", isPresented: Binding(get: { page.actionError != nil }, set: { if !$0 { page.dismissError() } })) {
            Button("OK") { page.dismissError() }
        } message: { Text(page.actionError ?? "") }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct ActionButton: View {
    let symbol: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { ActionLabel(symbol: symbol, label: label) }.buttonStyle(.plain)
    }
}

private struct ActionLabel: View {
    let symbol: String
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 48, height: 48)
                .background(.quaternary, in: Circle())
            Text(label).font(.caption.weight(.medium)).lineLimit(1)
        }
        .frame(width: 64)
        .contentShape(Rectangle())
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(width: size, height: size)
            .background(.quaternary, in: Circle())
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .contentShape(Circle())
    }
}

// MARK: - Side panel

private struct ShortSidePanel: View {
    let session: PlayerSession
    let panel: ShortsController.Panel
    var onClose: () -> Void

    private var page: WatchPageModel { session.page }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(panel == .comments ? "Comments" : "Description").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                Group {
                    if panel == .comments {
                        CommentsSection(page: page, player: session.player, showsHeader: false)
                    } else {
                        description
                    }
                }
                .padding(16)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.quaternary))
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(page.details?.title ?? session.video.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 10) {
                RemoteImage(url: page.details?.channel?.avatar).frame(width: 36, height: 36).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.details?.channel?.name ?? "").font(.headline)
                    if let subs = page.details?.channel?.subscribers { Text(subs).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            HStack(spacing: 22) {
                stat(page.displayedLikeCount, "Likes")
                stat(page.details?.shortViewCount ?? page.details?.viewCount, "Views")
                stat(page.details?.publishedDate, page.details?.publishedRelative ?? "")
            }
            if let text = page.details?.description, !text.isEmpty {
                Text(RichText.attributed(text)).textSelection(.enabled)
            } else if page.details == nil {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stat(_ value: String?, _ label: String) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                Text(value.replacingOccurrences(of: " views", with: "")).font(.headline)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Scroll paging

/// Turns trackpad/wheel scrolling into one-Short-at-a-time paging, ignoring scrolls that
/// land in a nested scroll view (the comments/description panel).
private struct ScrollPager: NSViewRepresentable {
    var onPage: (Int) -> Void

    func makeNSView(context: Context) -> PagerView { PagerView(onPage: onPage) }
    func updateNSView(_ v: PagerView, context: Context) { v.onPage = onPage }

    final class PagerView: NSView {
        var onPage: (Int) -> Void
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var cooldownUntil = Date.distantPast

        init(onPage: @escaping (Int) -> Void) {
            self.onPage = onPage
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            super.removeFromSuperview()
        }

        /// Returns true when the scroll was consumed for paging.
        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), !isOverNestedScrollView(event) else { return false }
            // Momentum after a page turn shouldn't turn another page.
            if Date() < cooldownUntil || event.momentumPhase != [] { return true }
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            accumulated += dy
            if abs(accumulated) > 60 {
                onPage(accumulated < 0 ? 1 : -1)
                accumulated = 0
                cooldownUntil = Date().addingTimeInterval(0.45)
            }
            if event.phase == .ended || event.phase == .cancelled { accumulated = 0 }
            return true
        }

        private func isOverNestedScrollView(_ event: NSEvent) -> Bool {
            var view = window?.contentView?.hitTest(event.locationInWindow)
            while let v = view {
                if v is NSScrollView { return true }
                view = v.superview
            }
            return false
        }
    }
}
