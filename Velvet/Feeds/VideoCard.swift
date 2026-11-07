import SwiftUI

/// A 16:9 video tile: thumbnail with badges and progress, then avatar, title and metadata.
struct VideoCard: View {
    let video: Video
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
            HStack(alignment: .top, spacing: 10) {
                RemoteImage(url: video.channelAvatar)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                    .opacity(video.channelAvatar == nil ? 0 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let channel = video.channelName {
                        Text(channel)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !metadataLine.isEmpty {
                        Text(metadataLine)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { VideoContextMenu(video: video) }
    }

    private var metadataLine: String {
        [video.viewCount, video.published].compactMap { $0 }.joined(separator: " · ")
    }

    private var thumbnail: some View {
        RemoteImage(url: video.thumbnail(minWidth: 480))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            .overlay(alignment: .bottom) {
                if let f = video.watchedFraction, f > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.4))
                            Rectangle().fill(.red).frame(width: geo.size.width * min(f, 1))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var badge: some View {
        switch video.kind {
        case .live:
            BadgeLabel(text: "LIVE", background: .red)
        case .upcoming:
            BadgeLabel(text: "UPCOMING", background: .black.opacity(0.75))
        default:
            if let d = video.duration { BadgeLabel(text: d, background: .black.opacity(0.75)) }
        }
    }
}

/// A vertical 9:16 Shorts tile.
struct ShortCard: View {
    let video: Video

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: video.thumbnail(minWidth: 300))
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(video.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
            if let views = video.viewCount {
                Text(views).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { VideoContextMenu(video: video) }
    }
}

struct BadgeLabel: View {
    let text: String
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct VideoContextMenu: View {
    let video: Video

    private var watchURL: URL {
        URL(string: video.kind == .short
            ? "https://www.youtube.com/shorts/\(video.id)"
            : "https://www.youtube.com/watch?v=\(video.id)")!
    }

    var body: some View {
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(watchURL.absoluteString, forType: .string)
        }
        Button("Open in Browser") { NSWorkspace.shared.open(watchURL) }
    }
}
