import SwiftUI
import AppKit

/// The watch page: player, details and comments, with related videos alongside (wide) or below (narrow).
struct WatchView: View {
    let session: PlayerSession
    @Environment(AppModel.self) private var app

    private var video: Video { session.video }
    private var page: WatchPageModel { session.page }

    /// The side column's height (wide layout): the page must be at least that tall.
    @State private var sideHeight: CGFloat = 0
    /// The scroll content's height, for the spacer that makes room for the side column.
    @State private var contentHeight: CGFloat = 0
    /// A last, empty row that makes the page as tall as the side column when the main
    /// column is shorter. (A minimum height on the stack itself broke its lazy layout.)
    @State private var spacerHeight: CGFloat = 0

    // The page is one lazy stack, the scroll view's direct content: the top (player, details)
    // and then each comment as its own row. The side column (related videos, chat, queue) is
    // laid over the right of it rather than beside it in an HStack. On macOS 15 a lazy stack
    // nested inside columns re-placed its rows on every scroll step: a fullscreen watch page on
    // an M1 scrolled at ~45 fps with ~100 hitches in 3 s. As the scroll view's direct content
    // it stays lazy (rows off screen are freed, a new page of comments costs only its rows).
    var body: some View {
        GeometryReader { geo in
            let theater = app.settings.theaterMode
            let wide = geo.size.width >= 1050
            let size = playerSize(in: geo.size, wide: wide)
            let sideInset = wide ? Self.relatedWidth + Self.columnSpacing : 0
            let bandHeight = theater ? theaterHeight(in: geo.size) : 0
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if theater {
                        // Theater: the player spans the page in a black band, the page continues below.
                        playerSlot(width: geo.size.width, height: bandHeight, theater: true)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        if !theater {
                            playerSlot(width: size.width, height: size.height, theater: false)
                                .frame(maxWidth: .infinity)
                        }
                        WatchInfoView(session: session)
                        if !wide, let chat = page.liveChat {
                            LiveChatPanel(chat: chat).frame(height: 420)
                        }
                        if !wide {
                            NextEpisodeCard(videoId: session.video.id)
                            QueuePreview()
                            RelatedList(page: page, columns: true)
                        }
                    }
                    .padding([.top, .leading], Self.padding)
                    .padding(.trailing, Self.padding + sideInset)
                    .padding(.bottom, 18)
                    CommentsSection(page: page, player: session.player,
                                    layout: .inline(leading: Self.padding, trailing: Self.padding + sideInset))
                    Color.clear.frame(height: Self.padding + spacerHeight)
                }
                .overlay(alignment: .topTrailing) {
                    if wide {
                        SideColumn(page: page, chatHeight: max(360, size.height + 120))
                            .frame(width: Self.relatedWidth)
                            // Its natural height: an overlay offers only the page's height, and
                            // squeezed into that the related titles dropped to one line.
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sideHeight = $0 }
                            .padding(.top, bandHeight + Self.padding)
                            .padding(.trailing, Self.padding)
                    }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                contentHeight = height
                updateSpacer(wide: wide, bandHeight: bandHeight)
            }
            .onChange(of: sideHeight) { updateSpacer(wide: wide, bandHeight: bandHeight) }
            .onChange(of: wide) { updateSpacer(wide: wide, bandHeight: bandHeight) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.watchViewport = $0 }
        }
        .navigationTitle(page.details?.title ?? video.title)
        .task(id: page.details?.videoId) {
            if let details = page.details { await app.noteSeriesEpisode(session, details: details) }
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

    /// Sizes the last row so the page is at least as tall as the side column.
    private func updateSpacer(wide: Bool, bandHeight: CGFloat) {
        let needed = wide ? bandHeight + Self.padding * 2 + sideHeight : 0
        let main = contentHeight - spacerHeight
        let next = max(0, (needed - main).rounded())
        if abs(next - spacerHeight) > 1 { spacerHeight = next }
    }

    private static let padding: CGFloat = 20
    private static let relatedWidth: CGFloat = 400
    private static let columnSpacing: CGFloat = 24

    /// Exact player size: full column width at the video's aspect ratio, shrunk (keeping the
    /// ratio) only when that would leave too little room below it. No letterbox padding.
    /// The player's slot. The player itself is drawn by RootView's PlayerLayer on top of it.
    private func playerSlot(width: CGFloat, height: CGFloat, theater: Bool) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.updatePlayerSlot($0, theater: theater) }
    }

    /// Theater band: the video's height at full width, capped so the title still shows below
    /// (the player letterboxes inside it, on black, like YouTube's).
    private func theaterHeight(in container: CGSize) -> CGFloat {
        min(container.width / aspect, max(240, container.height - 120)).rounded()
    }

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

            // Wide: channel and actions on one row. Narrower: actions under the channel.
            // Narrowest: icon-only buttons. Never squeeze (labels would wrap mid-word).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    channel
                    Spacer(minLength: 12)
                    actions(compact: false)
                }
                VStack(alignment: .leading, spacing: 12) {
                    channel
                    actions(compact: false)
                }
                VStack(alignment: .leading, spacing: 12) {
                    channel
                    actions(compact: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            descriptionBox
        }
    }

    private var channel: some View {
        HStack(spacing: 16) {
            Button {
                if let id = page.details?.channel?.id ?? video.channelId { app.openChannel(id) }
            } label: { channelLabel }
            .buttonStyle(.plain)
            .help("Go to channel")
            subscribeButton
        }
    }

    /// Shown once the page knows the channel (and so whether you're subscribed).
    @ViewBuilder
    private var subscribeButton: some View {
        if let channel = page.details?.channel, channel.id != nil {
            SubscribeButton(channelName: channel.name, isSubscribed: page.isSubscribed, bell: page.bell,
                            onSubscribe: { page.setSubscribed(true) },
                            onUnsubscribe: { page.setSubscribed(false) },
                            onBell: { page.setBell($0) })
        }
    }

    private var channelLabel: some View {
        HStack(spacing: 10) {
            RemoteImage(url: page.details?.channel?.avatar ?? video.channelAvatar)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(page.details?.channel?.name ?? video.channelName ?? "").font(.headline).lineLimit(1)
                if let subs = page.details?.channel?.subscribers {
                    Text(subs).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button { page.toggleLike() } label: {
                    Label(page.displayedLikeCount ?? "Like",
                          systemImage: page.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                Divider().frame(height: 16)
                Button { page.toggleDislike() } label: {
                    let symbol = page.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown"
                    if let count = page.displayedDislikeCount {
                        Label(count, systemImage: symbol)
                    } else {
                        Image(systemName: symbol)
                    }
                }
                .help(page.dislikeCount == nil ? "Dislike" : "Dislike (count from Return YouTube Dislike)")
                .task(id: app.settings.showDislikes) {
                    if app.settings.showDislikes { await page.loadDislikes() }
                }
            }
            .buttonStyle(PillButtonStyle())
            .background(.quaternary, in: Capsule())

            Button { page.toggleWatchLater() } label: {
                Label("Watch Later", systemImage: page.isInWatchLater ? "clock.fill" : "clock")
                    .labelStyle(CompactableLabelStyle(compact: compact))
            }
            .help("Watch Later")
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
                    .labelStyle(CompactableLabelStyle(compact: compact))
            }
            .help("Save to playlist")
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
        let v = [s.video.resolutionLabel, s.video.fps.map { String(Int($0)) + "fps" }, s.video.codecFamily?.label]
            .compactMap { $0 }.joined(separator: " ")
        let a = s.audio?.acodec?.components(separatedBy: ".").first ?? ""
        return a.isEmpty ? v : "\(v) · \(a)"
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
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
        VStack(spacing: 12) {
            NextEpisodeCard(videoId: page.videoId)
            QueuePreview()
            column
        }
    }

    @ViewBuilder
    private var column: some View {
        if let chat = page.liveChat {
            VStack(spacing: 12) {
                SegmentedTabs(tabs: [(true, "Chat"), (false, "Up Next")], selection: $showChat)
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

    /// Related videos minus members-only ones when those are hidden (watched ones stay: rewatching is common here).
    private var related: [Video] {
        page.related.filter { v in
            !app.dismissedVideos.contains(v.id) && !(app.settings.hideMembersOnly && v.isMembersOnly) && !app.aiFilter.hides(v)
                && (v.kind != .short || app.settings.showShortsShelf)
        }
    }

    /// YouTube puts Shorts in shelves between related videos. The parser keeps document
    /// order, so each run of consecutive Shorts is one shelf.
    private enum Segment: Identifiable {
        case videos([Video])
        case shorts([Video])
        var id: String {
            switch self {
            case .videos(let v): "v" + (v.first?.id ?? "")
            case .shorts(let v): "s" + (v.first?.id ?? "")
            }
        }
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        var run: [Video] = []
        var runIsShorts = false
        func flush() {
            guard !run.isEmpty else { return }
            out.append(runIsShorts ? .shorts(run) : .videos(run))
            run = []
        }
        for v in related {
            let isShort = v.kind == .short
            if isShort != runIsShorts { flush(); runIsShorts = isShort }
            run.append(v)
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if columns { Text("Up Next").font(.headline) }
            if page.relatedChips.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(page.relatedChips) { chip in
                            Chip(title: chip.title, isOn: chip.title == (page.selectedRelatedChip ?? page.relatedChips.first?.title)) {
                                Task { await page.selectRelatedChip(chip) }
                            }
                        }
                    }
                }
            }
            // A plain stack: this list sits in the side column (laid over the page) or inside one
            // row of the page's lazy stack, where a nested lazy stack would re-place its rows on
            // every scroll step (slow on macOS 15). It's a few dozen rows; the marker loads more.
            VStack(alignment: .leading, spacing: columns ? 18 : 10) {
                ForEach(segments) { segment in
                    switch segment {
                    case .shorts(let shorts):
                        ShortsShelf(shorts: shorts, cardWidth: columns ? 150 : 112) { app.open($0) }
                            .padding(.vertical, 6)
                    case .videos(let videos):
                        if columns {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14, alignment: .top)], spacing: 14) {
                                ForEach(videos) { v in
                                    Button { app.open(v) } label: { VideoCard(video: v) }.buttonStyle(.plain)
                                }
                            }
                        } else {
                            ForEach(videos) { v in
                                Button { app.open(v) } label: { RelatedRow(video: v) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            LoadMoreMarker(count: page.related.count) { await page.loadMoreRelated() }
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
            RemoteImage(url: brandedThumbnail ?? video.thumbnail(minWidth: 400),
                        fallback: brandedThumbnail == nil ? nil : video.thumbnail(minWidth: 400))
                .frame(width: 200, height: 112.5)
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

    enum Layout {
        /// Self-contained, in a panel with its own scroll view (Shorts).
        case panel
        /// Each part and each comment a separate row of the watch page's lazy stack, inset
        /// from its sides.
        case inline(leading: CGFloat, trailing: CGFloat)
    }
    var layout: Layout = .panel
    @Environment(AppModel.self) private var app
    /// Filters the comments loaded so far (YouTube has no comment search).
    @State private var query = ""

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Threads whose comment, author or loaded replies contain every word of the query.
    private var shown: [Comment] {
        guard searching else { return page.comments }
        let words = query.split(separator: " ").map(String.init)
        func matches(_ c: Comment) -> Bool {
            words.allSatisfy { c.text.localizedStandardContains($0) || c.author.localizedStandardContains($0) }
        }
        return page.comments.filter { c in matches(c) || (page.replies[c.id] ?? []).contains(where: matches) }
    }

    var body: some View {
        switch layout {
        case .panel:
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(shown) { c in
                        CommentRow(comment: c, page: page, threadId: c.id)
                            .onAppear { loadMoreIfLast(c) }
                    }
                }
                footer
            }
            .padding(.top, 6)
        case .inline(let leading, let trailing):
            // Separate rows (no container): in a lazy stack each becomes its own row.
            header
                .padding(.top, 6)
                .padding(.bottom, 16)
                .padding(.leading, leading).padding(.trailing, trailing)
            ForEach(shown) { c in
                CommentRow(comment: c, page: page, threadId: c.id)
                    .padding(.bottom, 18)
                    .padding(.leading, leading).padding(.trailing, trailing)
                    .onAppear { loadMoreIfLast(c) }
            }
            footer
                .padding(.leading, leading).padding(.trailing, trailing)
        }
    }

    /// The last comment on screen asks for the next page (rows appear as they scroll in).
    private func loadMoreIfLast(_ c: Comment) {
        // While searching, more pages load only when asked.
        if !searching, c.id == page.comments.last?.id { Task { await page.loadMoreComments() } }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader {
                HStack {
                    Text("Comments").font(.title3.weight(.semibold))
                    Spacer()
                    if !page.comments.isEmpty { searchField.frame(width: 220) }
                }
            } else if !page.comments.isEmpty {
                // In a panel with its own title (Shorts), the field gets the whole row.
                searchField.frame(maxWidth: .infinity)
            }
            if !page.hasComments && page.details != nil {
                Text("Comments are turned off or unavailable.").foregroundStyle(.secondary)
            }
            if page.canComment {
                HStack(alignment: .top, spacing: 12) {
                    RemoteImage(url: app.account?.photo)
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                    CommentComposer(placeholder: "Add a comment…", submitTitle: "Comment", collapses: true) {
                        await page.postComment($0)
                    }
                }
            }
            if searching {
                HStack {
                    Text(shown.isEmpty ? "No loaded comments match." : "\(shown.count) of \(page.comments.count) loaded comments match.")
                        .foregroundStyle(.secondary)
                    if page.canLoadMoreComments && !page.isLoadingComments {
                        Button("Load More to Search") { Task { await page.loadMoreComments() } }
                            .buttonStyle(.plain)
                            .fontWeight(.semibold)
                            .pointerStyle(.link)
                    }
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        if page.isLoadingComments {
            ProgressView().frame(maxWidth: .infinity)
        } else if page.hasComments && !page.commentsLoaded && !searching {
            // Fetch the first page only once the section scrolls into view.
            Color.clear.frame(height: 1).onAppear { Task { await page.loadMoreComments() } }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search comments", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(.primary.opacity(0.065)))
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
    }
}

/// A text box for a comment, reply or edit, with Cancel and submit buttons.
private struct CommentComposer: View {
    var placeholder: String
    var initialText = ""
    var submitTitle: String
    /// Top-level composer: just the field until it's used, like YouTube's.
    var collapses = false
    var onCancel: (() -> Void)?
    /// Returns true when posted (the field then clears / closes).
    var onSubmit: (String) async -> Bool

    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var expanded: Bool { !collapses || focused || !text.isEmpty }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($focused)
                .disabled(sending)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(focused ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary)).frame(height: 1)
                }
                .onKeyPress(.return, phases: .down) { press in
                    // ⌘↩ posts; plain ↩ adds a line.
                    guard press.modifiers.contains(.command) else { return .ignored }
                    submit()
                    return .handled
                }
            if expanded {
                HStack(spacing: 8) {
                    if sending { ProgressView().controlSize(.small) }
                    Button("Cancel") {
                        text = initialText.isEmpty || collapses ? "" : initialText
                        focused = false
                        onCancel?()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    Button(submitTitle) { submit() }
                        .buttonStyle(.prominent)
                        .disabled(trimmed.isEmpty || trimmed == initialText || sending)
                        .help("⌘↩")
                }
            }
        }
        .onAppear {
            text = initialText
            if !collapses { focused = true }
        }
    }

    private func submit() {
        let value = trimmed
        guard !value.isEmpty, value != initialText, !sending else { return }
        sending = true
        Task {
            if await onSubmit(value) {
                text = ""
                focused = false
            }
            sending = false
        }
    }
}

private struct CommentRow: View {
    let comment: Comment
    let page: WatchPageModel
    /// The top-level comment this one belongs to (itself for top-level comments).
    let threadId: String
    var isReply = false

    @State private var replying = false
    @State private var editing = false
    @State private var confirmingDelete = false

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
                if editing {
                    CommentComposer(placeholder: "Edit your comment", initialText: comment.text, submitTitle: "Save",
                                    onCancel: { editing = false }) { text in
                        let ok = await page.edit(comment, text: text)
                        if ok { editing = false }
                        return ok
                    }
                } else {
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
                    toolbar
                }
                if replying {
                    // Replying to a reply mentions its author, as YouTube does.
                    CommentComposer(placeholder: "Add a reply…", initialText: isReply ? "\(comment.author) " : "",
                                    submitTitle: "Reply", onCancel: { replying = false }) { text in
                        let ok = await page.reply(to: comment, inThread: threadId, text: text)
                        if ok { replying = false }
                        return ok
                    }
                }
                if !isReply { repliesBlock }
            }
        }
        .confirmationDialog("Delete your comment?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { page.delete(comment, inThread: isReply ? threadId : nil) }
        } message: {
            Text("It will be removed from YouTube permanently.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            let likes = comment.isLiked ? (comment.likeCountLiked ?? comment.likeCount) : comment.likeCount
            if comment.actions.like != nil {
                Button { page.toggleLike(comment) } label: {
                    Label(likes ?? "", systemImage: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .buttonStyle(.plain)
                .help(comment.isLiked ? "Unlike" : "Like")
            } else if let likes {
                Label(likes, systemImage: "hand.thumbsup")
            }
            if comment.actions.reply != nil {
                Button("Reply") { replying = true }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
            }
            if comment.actions.edit != nil || comment.actions.delete != nil {
                Menu {
                    if comment.actions.edit != nil { Button("Edit", systemImage: "pencil") { editing = true } }
                    if comment.actions.delete != nil {
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("More")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
                ForEach(loaded) { CommentRow(comment: $0, page: page, threadId: comment.id, isReply: true) }
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

/// Icon and title, or just the icon when space is tight.
private struct CompactableLabelStyle: LabelStyle {
    var compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 6) { configuration.icon; configuration.title }
        }
    }
}

/// "Next in this series" with Play and Add to Queue, when the video is a series episode and
/// the next one was found (and isn't already queued).
private struct NextEpisodeCard: View {
    let videoId: String
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.settings.seriesTracking, let entry = app.series.entry(for: videoId), let next = entry.next,
           !app.queue.items.contains(where: { $0.id == next.id }) {
            HStack(spacing: 12) {
                RemoteImage(url: next.thumbnail)
                    .frame(width: 112, height: 63)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next in this series").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(next.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 8) {
                        Button("Play", systemImage: "play.fill") { app.open(next.video) }
                        Button("Add to Queue", systemImage: "text.badge.plus") { app.addToQueue(next.video) }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// The end of a list in a plain stack: loads the next page when it scrolls into view. (A row's
/// onAppear would fire for every row at once outside a lazy stack.) Recreated when the list
/// grows, so a marker that's still on screen after a short page reports itself again.
private struct LoadMoreMarker: View {
    let count: Int
    let load: () async -> Void

    var body: some View {
        Color.clear
            .frame(height: 1)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                if visible { Task { await load() } }
            }
            .id(count)
    }
}
