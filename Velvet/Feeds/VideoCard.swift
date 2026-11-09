import SwiftUI

/// A 16:9 video tile: thumbnail with badges and progress, then avatar, title and metadata.
struct VideoCard: View {
    let video: Video
    @Environment(AppModel.self) private var app
    @State private var hovering = false
    @State private var prefetchTask: Task<Void, Never>?
    @State private var branding: DeArrowBranding?

    /// Originals show while hovering if the user asked for that.
    private var showOriginal: Bool { hovering && app.settings.deArrowOriginalOnHover }
    private var displayTitle: String { (showOriginal ? nil : branding?.title) ?? video.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
            HStack(alignment: .top, spacing: 10) {
                RemoteImage(url: video.channelAvatar)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                    .opacity(video.channelAvatar == nil ? 0 : 1)
                    .channelLink(video.channelId)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let channel = video.channelName {
                        Text(channel)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .channelLink(video.channelId)
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
        .padding(VideoGrid.cardInset)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { h in
            hovering = h
            // A short dwell filters out cards the pointer merely passes over.
            prefetchTask?.cancel()
            if h {
                prefetchTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { app.prefetch(video) }
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { VideoContextMenu(video: video) }
        .task(id: DeArrowKey(videoId: video.id, prefs: app.settings)) { branding = await app.branding(for: video) }
    }

    private var brandedThumbnail: URL? {
        guard !showOriginal, let t = branding?.thumbnailTime else { return nil }
        return DeArrowService.thumbnailURL(videoId: video.id, time: t)
    }

    private var metadataLine: String {
        [video.viewCount, video.published].compactMap { $0 }.joined(separator: " · ")
    }

    private var thumbnail: some View {
        RemoteImage(url: brandedThumbnail ?? video.thumbnail(minWidth: 480),
                    fallback: brandedThumbnail == nil ? nil : video.thumbnail(minWidth: 480))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            .overlay(alignment: .topLeading) {
                if video.isMembersOnly { MembersOnlyBadge().padding(6) }
            }
            .overlay(alignment: .bottom) {
                if let f = app.progress.fraction(for: video.id) ?? video.watchedFraction, f > 0.01 {
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
                .help(video.title) // titles are cut to two lines at this width
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
    @Environment(AppModel.self) private var app

    private var watchURL: URL {
        URL(string: video.kind == .short
            ? "https://www.youtube.com/shorts/\(video.id)"
            : "https://www.youtube.com/watch?v=\(video.id)")!
    }

    var body: some View {
        // Shorts open in their own player and upcoming streams can't play yet.
        if video.kind == .video || video.kind == .live {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { app.playNextQueued(video) }
            Button("Add to Queue", systemImage: "text.badge.plus") { app.addToQueue(video) }
            Divider()
        }
        if app.authState == .signedIn {
            Button("Save to Watch Later", systemImage: "clock") { app.saveToWatchLater(video) }
            Button("Save to Playlist…", systemImage: "music.note.list") { app.playlistPickerVideo = video }
            if video.notInterestedToken != nil || video.dontRecommendChannelToken != nil {
                Divider()
                if video.notInterestedToken != nil {
                    Button("Not Interested", systemImage: "eye.slash") { app.sendFeedback(for: video, channel: false) }
                }
                if video.dontRecommendChannelToken != nil {
                    Button("Don't Recommend Channel", systemImage: "nosign") { app.sendFeedback(for: video, channel: true) }
                }
            }
            Divider()
        }
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(watchURL.absoluteString, forType: .string)
        }
        Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(watchURL) }
        if let channelId = video.channelId {
            Divider()
            Button("Go to Channel", systemImage: "person.crop.square") { app.openChannel(channelId) }
        }
    }
}

/// Makes a channel name/avatar open the channel page. A high-priority tap so it wins over
/// the enclosing card's "open video" button; a pointing hand hints it's a separate target.
private struct ChannelLink: ViewModifier {
    let channelId: String?
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    func body(content: Content) -> some View {
        if let channelId {
            content
                .underline(hovering, color: .secondary)
                .onHover { hovering = $0 }
                .pointerStyle(.link)
                .highPriorityGesture(TapGesture().onEnded { app.openChannel(channelId) })
                .help("Go to channel")
        } else {
            content
        }
    }
}

extension View {
    func channelLink(_ channelId: String?) -> some View { modifier(ChannelLink(channelId: channelId)) }
}

/// Re-fetches branding when the video or any DeArrow setting changes.
struct DeArrowKey: Equatable {
    let videoId: String
    let titles: Bool
    let thumbnails: DeArrowThumbnailMode

    init(videoId: String, prefs: Preferences) {
        self.videoId = videoId
        titles = prefs.deArrowTitles
        thumbnails = prefs.deArrowThumbnails
    }
}

/// "★ Members only" tag for videos only the channel's paying members can watch.
struct MembersOnlyBadge: View {
    var body: some View {
        Label("Members only", systemImage: "star.fill")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(red: 0.13, green: 0.55, blue: 0.27), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help("Only the channel's members can watch this")
    }
}
