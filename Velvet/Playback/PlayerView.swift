import SwiftUI
import AppKit

/// Hosts mpv's Metal layer and keeps its drawable sized to the view in pixels.
struct VideoSurface: NSViewRepresentable {
    let player: MPVPlayer

    func makeNSView(context: Context) -> SurfaceView {
        SurfaceView(layer: player.layer) { [weak player] in player?.surfaceDidResize(to: $0) }
    }
    func updateNSView(_ nsView: SurfaceView, context: Context) {}

    final class SurfaceView: NSView {
        private let metal: CAMetalLayer
        private let onResize: (CGSize) -> Void

        init(layer: CAMetalLayer, onResize: @escaping (CGSize) -> Void) {
            metal = layer
            self.onResize = onResize
            super.init(frame: .zero)
            self.layer = layer // layer-hosting: mpv draws into it directly
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            syncDrawable()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            syncDrawable()
        }

        private func syncDrawable() {
            let scale = window?.backingScaleFactor ?? 2
            metal.contentsScale = scale
            metal.frame = bounds
            let pixels = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
            guard pixels != metal.drawableSize else { return }
            metal.drawableSize = pixels
            onResize(pixels)
        }
    }
}

/// Video plus auto-hiding controls and keyboard shortcuts.
struct PlayerView: View {
    let session: PlayerSession
    var isFullscreen: Bool
    var onToggleFullscreen: () -> Void

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var player: MPVPlayer { session.player }

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: player)
            statusOverlay
            if let resumed = session.resumedFrom {
                ResumeNotice(position: resumed) { session.startOver() } onDismiss: { session.resumedFrom = nil }
            }
            SponsorOverlay(skipper: session.sponsor)
                .padding(.bottom, controlsVisible || player.isPaused ? 76 : 20)
                .padding(.trailing, 16)
                .animation(.easeOut(duration: 0.2), value: controlsVisible)
            PlayerControls(session: session, isFullscreen: isFullscreen, onToggleFullscreen: onToggleFullscreen,
                           onInteract: showControls)
                .opacity(controlsVisible || player.isPaused ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: controlsVisible)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onToggleFullscreen() }
        .onTapGesture { player.togglePause(); showControls() }
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .onAppear { focused = true; showControls() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { handleKey($0) }
        .pointerVisibility(controlsVisible || player.isPaused ? .automatic : .hidden)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.phase {
        case .resolving:
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Finding streams…").foregroundStyle(.white.opacity(0.7)).font(.callout)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Try Again") { session.retry() }.buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .padding()
        case .ready:
            if player.isLoading || player.isBuffering {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
    }

    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        showControls()
        switch press.key {
        case .space: player.togglePause()
        case .leftArrow: player.seek(by: -5)
        case .rightArrow: player.seek(by: 5)
        case .upArrow: player.setVolume(player.volume + 5)
        case .downArrow: player.setVolume(player.volume - 5)
        case .escape:
            guard isFullscreen else { return .ignored }
            onToggleFullscreen()
        default:
            switch press.characters.lowercased() {
            case "k": player.togglePause()
            case "j": player.seek(by: -10)
            case "l": player.seek(by: 10)
            case "m": player.toggleMute()
            case "f": onToggleFullscreen()
            case ",": player.setSpeed(player.speed - 0.25)
            case ".": player.setSpeed(player.speed + 0.25)
            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                let tenth = Double(press.characters) ?? 0
                if player.duration > 0 { player.seek(to: player.duration * tenth / 10) }
            default: return .ignored
            }
        }
        return .handled
    }
}

struct PlayerControls: View {
    let session: PlayerSession
    var isFullscreen: Bool
    var onToggleFullscreen: () -> Void
    var onInteract: () -> Void

    @State private var scrubbing: Double?

    private var player: MPVPlayer { session.player }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                SeekBar(position: scrubbing ?? player.position, buffered: player.bufferedUntil,
                        duration: player.duration, isLive: session.video.kind == .live,
                        segments: session.sponsor.segments) { value, done in
                    scrubbing = done ? nil : value
                    if done { player.seek(to: value) }
                    onInteract()
                }
                HStack(spacing: 16) {
                    Button { player.togglePause() } label: {
                        Image(systemName: player.isPaused ? "play.fill" : "pause.fill").frame(width: 20)
                    }
                    Button { player.seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                    Button { player.seek(by: 10) } label: { Image(systemName: "goforward.10") }
                    VolumeControl(player: player)
                    Text(timeLabel).monospacedDigit().font(.callout).foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    speedMenu
                    qualityMenu
                    Button(action: onToggleFullscreen) {
                        Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }
    }

    private var timeLabel: String {
        if session.video.kind == .live { return "● LIVE" }
        return "\(Self.format(scrubbing ?? player.position)) / \(Self.format(player.duration))"
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { s in
                Button { player.setSpeed(s) } label: {
                    if abs(player.speed - s) < 0.01 { Label(s == 1 ? "Normal" : "\(s.formatted())×", systemImage: "checkmark") }
                    else { Text(s == 1 ? "Normal" : "\(s.formatted())×") }
                }
            }
        } label: {
            Text(abs(player.speed - 1) < 0.01 ? "1×" : "\(player.speed.formatted())×").monospacedDigit()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(session.availableQualities) { q in
                Button { session.setQuality(q) } label: {
                    if q == session.quality { Label(q.label, systemImage: "checkmark") } else { Text(q.label) }
                }
            }
        } label: {
            Text(session.selection?.video.height.map { String($0) + "p" } ?? "Auto")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(session.info == nil || session.video.kind == .live)
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct VolumeControl: View {
    let player: MPVPlayer
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button { player.toggleMute() } label: {
                Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill"
                      : player.volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                    .frame(width: 22, alignment: .leading)
            }
            if hovering {
                Slider(value: Binding(get: { player.isMuted ? 0 : player.volume }, set: { player.setVolume($0) }), in: 0...100)
                    .frame(width: 80)
                    .controlSize(.mini)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// Seek bar with buffered range; reports (value, finished).
struct SeekBar: View {
    let position: Double
    let buffered: Double
    let duration: Double
    var isLive = false
    var segments: [SponsorSegment] = []
    var onScrub: (Double, Bool) -> Void

    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac: (Double) -> CGFloat = { duration > 0 ? CGFloat(min(max($0 / duration, 0), 1)) * w : 0 }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white.opacity(0.4)).frame(width: frac(buffered))
                ForEach(segments) { seg in
                    Rectangle().fill(seg.category.color.opacity(0.9))
                        .frame(width: max(2, frac(seg.end) - frac(seg.start)))
                        .offset(x: frac(seg.start))
                }
                Capsule().fill(.red).frame(width: frac(position))
                Circle().fill(.red)
                    .frame(width: hovering ? 13 : 0, height: hovering ? 13 : 0)
                    .offset(x: frac(position) - (hovering ? 6.5 : 0))
            }
            .frame(height: hovering ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onScrub(value(at: $0.location.x, width: w), false) }
                .onEnded { onScrub(value(at: $0.location.x, width: w), true) })
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        }
        .frame(height: 16)
        .opacity(isLive || duration <= 0 ? 0.4 : 1)
        .allowsHitTesting(!isLive && duration > 0)
    }

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }
}

/// "Skip" button for ask-first segments and the "Skipped · Undo" notice.
struct SponsorOverlay: View {
    let skipper: SponsorSkipper

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer()
            if let seg = skipper.lastSkip {
                HStack(spacing: 10) {
                    Circle().fill(seg.category.color).frame(width: 8, height: 8)
                    Text("Skipped \(seg.category.shortLabel)")
                    Button("Undo") { skipper.undoLastSkip() }.buttonStyle(.plain).bold()
                }
                .modifier(OverlayPill())
            }
            if let seg = skipper.offered {
                Button { skipper.skipOffered() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(seg.category.color).frame(width: 8, height: 8)
                        Text("Skip \(seg.category.shortLabel)")
                        Image(systemName: "forward.end.fill")
                    }
                }
                .buttonStyle(.plain)
                .modifier(OverlayPill())
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.easeOut(duration: 0.2), value: skipper.offered)
        .animation(.easeOut(duration: 0.2), value: skipper.lastSkip)
    }
}

private struct OverlayPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.7), in: Capsule())
            .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}

/// "Resumed from 4:12 · Start Over", shown briefly after an automatic resume.
struct ResumeNotice: View {
    let position: Double
    var onStartOver: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Resumed from \(PlayerControls.format(position))")
                Button("Start Over", action: onStartOver).buttonStyle(.plain).bold()
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(.top, 14)
            Spacer()
        }
        .transition(.opacity)
        .task {
            try? await Task.sleep(for: .seconds(6))
            withAnimation { onDismiss() }
        }
    }
}
