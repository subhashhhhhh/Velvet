import SwiftUI
import AppKit

/// The watch page: player, details and comments, with related videos alongside (wide) or below (narrow).
struct WatchView: View {
    let session: PlayerSession
    @Environment(AppModel.self) private var app

    private var video: Video { session.video }
    private var page: WatchPageModel { session.page }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 1050
            let size = playerSize(in: geo.size, wide: wide)
            ScrollView {
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    VStack(alignment: .leading, spacing: 18) {
                        // The player's slot. The player is drawn by RootView's PlayerLayer on top.
                        Color.clear
                            .frame(width: size.width, height: size.height)
                            .frame(maxWidth: .infinity)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.playerSlot = $0 }
                        WatchInfoView(session: session)
                        if !wide, let chat = page.liveChat {
                            LiveChatPanel(chat: chat).frame(height: 420)
                        }
                        if !wide { RelatedList(page: page, columns: true) }
                        CommentsSection(page: page, player: session.player)
                    }
                    .frame(maxWidth: .infinity)
                    if wide {
                        SideColumn(page: page, chatHeight: max(360, size.height + 120))
                            .frame(width: Self.relatedWidth)
                    }
                }
                .padding(Self.padding)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.watchViewport = $0 }
        }
        .navigationTitle(page.details?.title ?? video.title)
        .toolbar(app.playerFullscreen ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { app.closePlayer() }
                    .keyboardShortcut("[", modifiers: .command)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            // Covers leaving fullscreen via the green button or Mission Control, not just our controls.
            app.windowDidExitFullscreen()
        }
        .alert("Couldn't Complete That", isPresented: Binding(get: { page.actionError != nil }, set: { if !$0 { page.dismissError() } })) {
            Button("OK") { page.dismissError() }
        } message: {
            Text(page.actionError ?? "")
        }
        // Timestamp links (velvet-seek://<seconds>) in descriptions and comments seek the player.
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "velvet-seek", let seconds = Double(url.host() ?? "") {
                session.player.seek(to: seconds)
                session.player.play()
                return .handled
            }
            return .systemAction
        })
    }

    private static let padding: CGFloat = 20
    private static let relatedWidth: CGFloat = 360
    private static let columnSpacing: CGFloat = 24

    /// Exact player size: full column width at the video's aspect ratio, shrunk (keeping the
    /// ratio) only when that would leave too little room below it. No letterbox padding.
    private func playerSize(in container: CGSize, wide: Bool) -> CGSize {
        let columnWidth = container.width - Self.padding * 2 - (wide ? Self.relatedWidth + Self.columnSpacing : 0)
        let maxHeight = max(240, container.height - 170)
        var width = max(200, columnWidth)
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Shorts are vertical; everything else is 16:9 until mpv reports the real size.
    private var aspect: CGFloat {
        if let size = session.player.videoSize, size.width > 0, size.height > 0 { return size.width / size.height }
        return video.kind == .short ? 9 / 16 : 16 / 9
    }
}

// MARK: - Info

private struct WatchInfoView: View {
    let session: PlayerSession
    @Environment(AppModel.self) private var app
    @State private var descriptionExpanded = false
    @State private var branding: DeArrowBranding?
    @State private var titleHovered = false

    private var page: WatchPageModel { session.page }
    private var video: Video { session.video }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let original = page.details?.title ?? video.title
            Text((titleHovered && app.settings.deArrowOriginalOnHover ? nil : branding?.title) ?? original)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .onHover { titleHovered = $0 }
                .help(branding?.title != nil ? "Original: \(original)" : "")
                .task(id: DeArrowKey(videoId: video.id, prefs: app.settings)) { branding = await app.branding(for: video) }

            HStack(alignment: .center, spacing: 12) {
                channel
                Spacer(minLength: 12)
                actions
            }

            descriptionBox
        }
    }

    private var channel: some View {
        Button {
            if let id = page.details?.channel?.id ?? video.channelId { app.openChannel(id) }
        } label: { channelLabel }
        .buttonStyle(.plain)
        .help("Go to channel")
    }

    private var channelLabel: some View {
        HStack(spacing: 10) {
            RemoteImage(url: page.details?.channel?.avatar ?? video.channelAvatar)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(page.details?.channel?.name ?? video.channelName ?? "").font(.headline)
                if let subs = page.details?.channel?.subscribers {
                    Text(subs).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button { page.toggleLike() } label: {
                    Label(page.displayedLikeCount ?? "Like",
                          systemImage: page.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                Divider().frame(height: 16)
                Button { page.toggleDislike() } label: {
                    Image(systemName: page.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .help("Dislike")
            }
            .buttonStyle(PillButtonStyle())
            .background(.quaternary, in: Capsule())

            Button { page.toggleWatchLater() } label: {
                Label("Watch Later", systemImage: page.isInWatchLater ? "clock.fill" : "clock")
            }
            .buttonStyle(PillButtonStyle())
            .background(.quaternary, in: Capsule())

            Menu {
                if page.playlists.isEmpty {
                    Text(app.authState == .signedIn ? "Loading playlists…" : "Sign in to save videos")
                } else {
                    ForEach(page.playlists) { p in
                        Toggle(isOn: Binding(get: { p.containsVideo }, set: { page.setPlaylist(p.id, $0) })) {
                            Label(p.title, systemImage: p.isWatchLater ? "clock" : (p.isPrivate ? "lock" : "list.bullet"))
                        }
                    }
                }
            } label: {
                Label("Save", systemImage: "text.badge.plus")
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle())
            .background(.quaternary, in: Capsule())
            .fixedSize()

            Menu {
                Button("Copy Link") { copy(watchURL(at: nil)) }
                Button("Copy Link at Current Time") { copy(watchURL(at: session.player.position)) }
                Divider()
                Button("Open in Browser") { NSWorkspace.shared.open(watchURL(at: session.player.position)) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(PillButtonStyle())
            .background(.quaternary, in: Capsule())
            .fixedSize()
        }
        .labelStyle(.titleAndIcon)
    }

    private var descriptionBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([page.details?.viewCount ?? video.viewCount,
                  page.details?.publishedDate ?? page.details?.publishedRelative ?? video.published]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline.weight(.semibold))
            if let text = page.details?.description, !text.isEmpty {
                Text(RichText.attributed(text))
                    .font(.body)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .textSelection(.enabled)
                Button(descriptionExpanded ? "Show less" : "…more") {
                    withAnimation(.easeOut(duration: 0.15)) { descriptionExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
            } else if page.details == nil && page.loadError == nil {
                ProgressView().controlSize(.small)
            }
            if let s = session.selection {
                Text(streamLabel(s)).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func watchURL(at time: Double?) -> URL {
        var s = "https://www.youtube.com/watch?v=\(video.id)"
        if let time, time >= 1 { s += "&t=\(Int(time))s" }
        return URL(string: s)!
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func streamLabel(_ s: StreamInfo.Selection) -> String {
        let v = [s.video.height.map { String($0) + "p" }, s.video.fps.map { String(Int($0)) + "fps" }, s.video.codecFamily?.label]
            .compactMap { $0 }.joined(separator: " ")
        let a = s.audio?.acodec?.components(separatedBy: ".").first ?? ""
        return a.isEmpty ? v : "\(v) · \(a)"
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Side column (live chat / related)

/// Wide layout's right column: for live streams a Chat / Up Next switcher, else related videos.
private struct SideColumn: View {
    let page: WatchPageModel
    let chatHeight: CGFloat
    @State private var showChat = true

    var body: some View {
        if let chat = page.liveChat {
            VStack(spacing: 12) {
                Picker("", selection: $showChat) {
                    Text("Chat").tag(true)
                    Text("Up Next").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if showChat {
                    LiveChatPanel(chat: chat).frame(height: chatHeight)
                } else {
                    RelatedList(page: page, columns: false)
                }
            }
        } else {
            RelatedList(page: page, columns: false)
        }
    }
}

// MARK: - Related

private struct RelatedList: View {
    let page: WatchPageModel
    /// Narrow layout: show related as a grid of cards instead of a column of rows.
    var columns: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if columns {
                Text("Up Next").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(page.related) { v in
                        Button { app.open(v) } label: { VideoCard(video: v) }.buttonStyle(.plain)
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(page.related) { v in
                        Button { app.open(v) } label: { RelatedRow(video: v) }
                            .buttonStyle(.plain)
                            .onAppear {
                                if v.id == page.related.last?.id { Task { await page.loadMoreRelated() } }
                            }
                    }
                }
            }
            if page.isLoadingRelated || (page.details == nil && page.loadError == nil) {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }
}

private struct RelatedRow: View {
    let video: Video
    @Environment(AppModel.self) private var app
    @State private var hovering = false
    @State private var prefetch: Task<Void, Never>?
    @State private var branding: DeArrowBranding?

    private var showOriginal: Bool { hovering && app.settings.deArrowOriginalOnHover }
    private var brandedThumbnail: URL? {
        guard !showOriginal, let t = branding?.thumbnailTime else { return nil }
        return DeArrowService.thumbnailURL(videoId: video.id, time: t)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: brandedThumbnail ?? video.thumbnail(minWidth: 336),
                        fallback: brandedThumbnail == nil ? nil : video.thumbnail(minWidth: 336))
                .frame(width: 168, height: 94.5)
                .overlay(alignment: .topLeading) {
                    if video.isMembersOnly { MembersOnlyBadge().scaleEffect(0.85, anchor: .topLeading).padding(4) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if video.kind == .live { BadgeLabel(text: "LIVE", background: .red).padding(4) }
                    else if let d = video.duration { BadgeLabel(text: d, background: .black.opacity(0.75)).padding(4) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text((showOriginal ? nil : branding?.title) ?? video.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if let c = video.channelName { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1).channelLink(video.channelId) }
                Text([video.viewCount, video.published].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            prefetch?.cancel()
            if h { prefetch = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { app.prefetch(video) } } }
        }
        .contextMenu { VideoContextMenu(video: video) }
        .task(id: DeArrowKey(videoId: video.id, prefs: app.settings)) { branding = await app.branding(for: video) }
    }
}

// MARK: - Comments

struct CommentsSection: View {
    let page: WatchPageModel
    let player: MPVPlayer
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader { Text("Comments").font(.title3.weight(.semibold)) }
            if !page.hasComments && page.details != nil {
                Text("Comments are turned off or unavailable.").foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(page.comments) { c in
                    CommentRow(comment: c, page: page)
                        .onAppear {
                            if c.id == page.comments.last?.id { Task { await page.loadMoreComments() } }
                        }
                }
            }
            if page.isLoadingComments {
                ProgressView().frame(maxWidth: .infinity)
            } else if page.hasComments && !page.commentsLoaded {
                // Fetch the first page only once the section scrolls into view.
                Color.clear.frame(height: 1).onAppear { Task { await page.loadMoreComments() } }
            }
        }
        .padding(.top, 6)
    }
}

private struct CommentRow: View {
    let comment: Comment
    let page: WatchPageModel
    var isReply = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: comment.avatar)
                .frame(width: isReply ? 28 : 36, height: isReply ? 28 : 36)
                .clipShape(Circle())
                .channelLink(comment.authorChannelId)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.author)
                        .font(.subheadline.weight(.semibold))
                        .channelLink(comment.authorChannelId)
                        .padding(.horizontal, comment.isCreator ? 6 : 0)
                        .background(comment.isCreator ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
                    if comment.isVerified { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.secondary) }
                    if let t = comment.published { Text(t).font(.caption).foregroundStyle(.secondary) }
                }
                if !comment.text.isEmpty {
                    Text(RichText.attributed(comment.text))
                        .font(.body)
                        .textSelection(.enabled)
                }
                if let gif = comment.gif {
                    // Fit within 200pt tall / 280pt wide, keeping the GIF's shape.
                    let scale = min(200 / max(gif.height, 1), 280 / max(gif.width, 1), 1)
                    AnimatedImage(url: gif.url)
                        .frame(width: gif.width * scale, height: gif.height * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                HStack(spacing: 14) {
                    if let likes = comment.likeCount {
                        Label(likes, systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !isReply { repliesBlock }
            }
        }
    }

    @ViewBuilder
    private var repliesBlock: some View {
        let loaded = page.replies[comment.id]
        if comment.replyCount > 0 {
            Button {
                if loaded == nil { Task { await page.loadReplies(for: comment) } } else { page.hideReplies(for: comment) }
            } label: {
                Label(loaded == nil ? "\(comment.replyCount) \(comment.replyCount == 1 ? "reply" : "replies")" : "Hide replies",
                      systemImage: loaded == nil ? "chevron.down" : "chevron.up")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        if let loaded {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(loaded) { CommentRow(comment: $0, page: page, isReply: true) }
                if page.hasMoreReplies(comment) {
                    Button("Show more replies") { Task { await page.loadReplies(for: comment) } }
                        .buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            .padding(.top, 6)
        }
        if page.loadingReplies.contains(comment.id) { ProgressView().controlSize(.small) }
    }
}

// MARK: - Rich text

/// Turns plain YouTube text into tappable links: URLs open in the browser, timestamps seek.
enum RichText {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let timestamp = try? NSRegularExpression(pattern: #"(?<![\d:])(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?![\d:])"#)

    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        for match in detector?.matches(in: text, range: full) ?? [] {
            guard let url = match.url, let range = Range(match.range, in: out) else { continue }
            out[range].link = url
        }
        for match in timestamp?.matches(in: text, range: full) ?? [] {
            guard let range = Range(match.range, in: out), out[range].link == nil else { continue }
            func part(_ i: Int) -> Int { match.range(at: i).location == NSNotFound ? 0 : Int(ns.substring(with: match.range(at: i))) ?? 0 }
            let seconds = part(1) * 3600 + part(2) * 60 + part(3)
            out[range].link = URL(string: "velvet-seek://\(seconds)")
        }
        return out
    }
}
