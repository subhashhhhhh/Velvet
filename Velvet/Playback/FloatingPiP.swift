import AppKit
import SwiftUI

/// Velvet's own Picture in Picture: a borderless floating panel, like Arc's/Chromium's.
///
/// Unlike the system PiP it opens instantly on any macOS version, and it has a real
/// seek bar. It joins every Space and floats over other apps' fullscreen windows.
final class FloatingPiP: NSObject, NSWindowDelegate {
    private(set) var panel: FloatingPiPPanel?
    private weak var player: MPVPlayer?

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onSkipToLive: (() -> Void)?
    /// Closed; true when the user asked to return to the app.
    var onClosed: ((_ restored: Bool) -> Void)?
    var onRestoreRequested: (() -> Void)?

    private static let frameKey = "floatingPiP.frame"
    private static let margin: CGFloat = 16
    private static let defaultWidth: CGFloat = 320

    var isActive: Bool { panel != nil }

    /// Shows `view` (the video surface) in the panel. `from` is the inline player's screen
    /// rect: the panel grows out of it to its corner.
    func enter(view: NSView, aspect: CGSize, player: MPVPlayer, isLive: Bool, from: NSRect?, screen: NSScreen?) {
        guard panel == nil else { return }
        self.player = player
        let aspect = aspect.width > 0 && aspect.height > 0 ? aspect : CGSize(width: 16, height: 9)
        let screen = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let target = Self.restoredFrame(aspect: aspect, on: screen)

        _ = from // fly-in from the page looked oversized; appear in place instead
        let panel = FloatingPiPPanel(contentRect: target)
        panel.delegate = self
        panel.contentAspectRatio = aspect
        panel.minSize = NSSize(width: 240, height: 240 * aspect.height / aspect.width)

        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view.frame = root.bounds
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)

        let controls = NSHostingView(rootView: FloatingPiPControls(
            player: player, isLive: isLive,
            onClose: { [weak self] in self?.close(restore: false, pause: true) },
            onReturn: { [weak self] in self?.close(restore: true, pause: false) },
            onGoLive: { [weak self] in self?.onSkipToLive?() },
            onDragEnded: {}
        ))
        controls.frame = root.bounds
        controls.autoresizingMask = [.width, .height]
        root.addSubview(controls)
        panel.contentView = root

        self.panel = panel
        restingFrame = target
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animate(0.18) { _ in panel.animator().alphaValue = 1 }
    }

    /// Ends PiP from the app (e.g. back on the watch page): fly back to `to` (screen rect).
    func exit(to: NSRect?) {
        finish(restored: false, to: to)
    }

    private func close(restore: Bool, pause: Bool) {
        guard panel != nil else { return }
        if pause { onPause?() }
        if restore { onRestoreRequested?() }
        finish(restored: restore, to: restore ? returnRect?() : nil)
    }

    /// Where "return to app" should fly to (the inline player's screen rect), if known.
    var returnRect: (() -> NSRect?)?

    private var isClosing = false

    private func finish(restored: Bool, to: NSRect?) {
        guard let panel, !isClosing else { return }
        isClosing = true
        if let restingFrame { saveFrame(restingFrame) }
        let done = { [weak self] in
            guard let self else { return }
            panel.orderOut(nil)
            panel.contentView = nil
            self.panel = nil
            self.isClosing = false
            self.onClosed?(restored)
        }
        guard let to else {
            animate(0.18, { _ in panel.animator().alphaValue = 0 }, completion: done)
            return
        }
        animate(0.3, { _ in panel.animator().setFrame(to, display: true) }, completion: done)
    }

    func setAspect(_ aspect: CGSize) {
        guard let panel, aspect.width > 0, aspect.height > 0 else { return }
        panel.contentAspectRatio = aspect
        var f = panel.frame
        f.size.height = f.width * aspect.height / aspect.width
        panel.setFrame(f, display: true)
        restingFrame = f
    }

    // MARK: - Placement

    /// Exactly where and how big the user last left it (kept on screen), else bottom-right.
    private static func restoredFrame(aspect: CGSize, on screen: NSScreen) -> NSRect {
        let saved = UserDefaults.standard.string(forKey: frameKey).map(NSRectFromString)
        // Use the screen the saved frame was on, if it's still connected.
        let home = saved.flatMap { f in NSScreen.screens.first { $0.frame.intersects(f) } } ?? screen
        let visible = home.visibleFrame
        let width = min(max(saved?.width ?? defaultWidth, 200), visible.width * 0.6)
        let size = NSSize(width: width, height: width * aspect.height / aspect.width)
        guard let saved, saved.width > 0 else {
            return frame(size: size, corner: CGPoint(x: 1, y: 0), in: visible)
        }
        // Keep the top-left corner where it was (resizing changes height with aspect ratio).
        var origin = CGPoint(x: saved.minX, y: saved.maxY - size.height)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    private static func frame(size: NSSize, corner: CGPoint, in visible: NSRect) -> NSRect {
        let x = corner.x > 0 ? visible.maxX - size.width - margin : visible.minX + margin
        let y = corner.y > 0 ? visible.maxY - size.height - margin : visible.minY + margin
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func saveFrame(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
    }

    /// The frame the user chose (not mid-animation), saved when PiP closes.
    private var restingFrame: NSRect?

    func windowDidEndLiveResize(_ notification: Notification) {
        // Animated setFrame (our fly-back) also counts as a live resize; ignore those.
        guard !animating, !isClosing, let panel else { return }
        restingFrame = panel.frame
        saveFrame(panel.frame)
    }

    /// Our own animations move/resize the panel too; only the user's changes are remembered.
    private var animating = false
    func windowDidMove(_ notification: Notification) {
        guard !animating, !isClosing, let panel else { return }
        restingFrame = panel.frame
    }

    func windowDidResize(_ notification: Notification) {
        guard !animating, !isClosing, let panel else { return }
        restingFrame = panel.frame
    }

    private func animate(_ duration: Double, _ changes: @escaping (NSAnimationContext) -> Void, completion: (() -> Void)? = nil) {
        animating = true
        // AppKit calls the completion handler on the main thread.
        nonisolated(unsafe) let completion = completion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            changes(ctx)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.animating = false
                completion?()
            }
        })
    }
}

/// Borderless, non-activating floating panel that follows you across Spaces and sits over
/// other apps' fullscreen windows. Clicking it never pulls Velvet forward.
final class FloatingPiPPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isMovable = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controls

struct FloatingPiPControls: View {
    let player: MPVPlayer
    let isLive: Bool
    var onClose: () -> Void
    var onReturn: () -> Void
    var onGoLive: () -> Void
    var onDragEnded: () -> Void

    @State private var hovering = false
    @State private var scrubbing: Double?

    var body: some View {
        ZStack {
            // Drag anywhere (except on a control) to move; double-click to go back to Velvet.
            WindowDragArea(onDragEnded: onDragEnded, onDoubleClick: onReturn)

            if hovering {
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    HStack {
                        iconButton("xmark", help: "Close", action: onClose)
                        Spacer()
                        iconButton("pip.exit", help: "Back to Velvet", action: onReturn)
                    }
                    Spacer()
                    HStack(spacing: 28) {
                        if !isLive { iconButton("gobackward.10", size: 18) { player.seek(by: -10) } }
                        iconButton(player.isPaused ? "play.fill" : "pause.fill", size: 26) { player.togglePause() }
                        if !isLive { iconButton("goforward.10", size: 18) { player.seek(by: 10) } }
                    }
                    Spacer()
                    if isLive {
                        HStack {
                            Button("LIVE", action: onGoLive).buttonStyle(.plain)
                                .font(.caption.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.red, in: RoundedRectangle(cornerRadius: 4))
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 2) {
                            SeekBar(position: scrubbing ?? player.position, buffered: player.bufferedUntil,
                                    duration: player.duration) { value, done in
                                scrubbing = done ? nil : value
                                if done { player.seek(to: value) }
                            }
                            HStack {
                                Text(PlayerControls.format(scrubbing ?? player.position))
                                Spacer()
                                Text(PlayerControls.format(player.duration))
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .padding(10)
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private func iconButton(_ symbol: String, size: CGFloat = 14, help: String = "",
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size + 16, height: size + 16)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.4), radius: 3)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Moves the window with the system's own drag loop (smooth, snaps to Spaces correctly).
private struct WindowDragArea: NSViewRepresentable {
    var onDragEnded: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DragView {
        let v = DragView()
        v.onDragEnded = onDragEnded
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ v: DragView, context: Context) {
        v.onDragEnded = onDragEnded
        v.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView {
        var onDragEnded: (() -> Void)?
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick?(); return }
            guard let window else { return }
            let start = window.frame.origin
            window.performDrag(with: event)
            if window.frame.origin != start { onDragEnded?() }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
