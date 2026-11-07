import SwiftUI
import AppKit

/// The watch page: player on top, video details below. In fullscreen it's just the player.
struct WatchView: View {
    let session: PlayerSession
    @Environment(AppModel.self) private var app

    private var video: Video { session.video }

    var body: some View {
        Group {
            if app.playerFullscreen {
                player.ignoresSafeArea()
            } else {
                GeometryReader { geo in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            player
                                .aspectRatio(aspect, contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: max(240, geo.size.height - 150))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            details
                        }
                        .padding(20)
                    }
                }
            }
        }
        .navigationTitle(video.title)
        .toolbar(app.playerFullscreen ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { app.closePlayer() }
                    .keyboardShortcut("[", modifiers: .command)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            // Covers leaving fullscreen via the green button or Mission Control, not just our controls.
            if app.playerFullscreen { app.playerFullscreen = false }
        }
    }

    private var player: some View {
        PlayerView(session: session, isFullscreen: app.playerFullscreen) { app.togglePlayerFullscreen() }
    }

    /// Shorts are vertical; everything else is 16:9 until mpv reports the real size.
    private var aspect: CGFloat {
        if let size = session.player.videoSize, size.width > 0, size.height > 0 { return size.width / size.height }
        return video.kind == .short ? 9 / 16 : 16 / 9
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(video.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 10) {
                RemoteImage(url: video.channelAvatar)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                    .opacity(video.channelAvatar == nil ? 0 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.channelName ?? session.info?.channel ?? "").font(.headline)
                    Text([video.viewCount, video.published].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let s = session.selection {
                    Text(streamLabel(s))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func streamLabel(_ s: StreamInfo.Selection) -> String {
        let v = [s.video.height.map { "\($0)p" }, s.video.fps.map { "\(Int($0))fps" }, s.video.codecFamily?.label]
            .compactMap { $0 }.joined(separator: " ")
        let a = s.audio?.acodec?.components(separatedBy: ".").first ?? ""
        return a.isEmpty ? v : "\(v) · \(a)"
    }
}
