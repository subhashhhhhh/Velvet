import SwiftUI
import AppKit

/// What's inside the PiP window: the video, plus Velvet's own seek bar on hover (PIP.framework's
/// native scrubber has no documented seek callback, so we draw ours).
struct PictureInPictureContent: View {
    let surface: MPVSurfaceView
    let player: MPVPlayer
    var isLive: Bool
    var segments: [SponsorSegment]

    #if DEBUG
    /// `-VelvetPiPControls YES` keeps the bar visible initially (for screenshots).
    @State private var hovering = UserDefaults.standard.bool(forKey: "VelvetPiPControls")
    #else
    @State private var hovering = false
    #endif
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            HostedView(view: surface)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if hovering || scrubbing != nil {
                controls.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onContinuousHover { phase in
            switch phase {
            case .active: show()
            case .ended: hideSoon(after: 0.4)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 4) {
            if isLive {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("LIVE").font(.caption.weight(.bold))
                    Spacer()
                }
            } else {
                SeekBar(position: scrubbing ?? player.position, buffered: player.bufferedUntil,
                        duration: player.duration, segments: segments) { value, done in
                    scrubbing = done ? nil : value
                    if done { player.seek(to: value) }
                    show()
                }
                HStack {
                    Text(PlayerControls.format(scrubbing ?? player.position))
                    Spacer()
                    Text("-" + PlayerControls.format(max(0, player.duration - (scrubbing ?? player.position))))
                }
                .font(.caption2.monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    private func show() {
        hovering = true
        hideSoon(after: 2.5)
    }

    private func hideSoon(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled && scrubbing == nil { hovering = false }
        }
    }
}

/// Embeds an existing NSView (mpv's surface) in SwiftUI.
private struct HostedView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
