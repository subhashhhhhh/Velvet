import Foundation
import OSLog

/// Watch-page data around the player: details, actions, related videos and comments.
@Observable
final class WatchPageModel {
    let videoId: String
    private(set) var details: WatchDetails?
    private(set) var loadError: String?

    // Account actions (optimistic: update first, roll back on failure).
    private(set) var likeStatus: LikeStatus = .none
    private(set) var isSubscribed = false
    private(set) var bell: ChannelBell?
    private(set) var playlists: [PlaylistOption] = []
    private(set) var actionError: String?

    // Related
    private(set) var related: [Video] = []
    private(set) var isLoadingRelated = false

    // Comments
    private(set) var comments: [Comment] = []
    private(set) var isLoadingComments = false
    private(set) var commentsLoaded = false
    private(set) var replies: [String: [Comment]] = [:]
    private(set) var loadingReplies: Set<String> = []
    /// Parameters for posting a top-level comment; nil when signed out or comments are off.
    private(set) var createCommentParams: String?
    var canComment: Bool { signedIn && createCommentParams != nil }

    var isInWatchLater: Bool { playlists.first(where: \.isWatchLater)?.containsVideo ?? false }

    /// Live chat, for live streams that have it (starts when the page loads).
    private(set) var liveChat: LiveChatModel?

    func stopLiveChat() { liveChat?.stop() }

    @ObservationIgnored private let client: InnerTubeClient
    /// Read at action time, not at open time, so a session restored a moment later still counts.
    @ObservationIgnored private let isSignedIn: () -> Bool
    private var signedIn: Bool { isSignedIn() }
    @ObservationIgnored private var relatedToken: String?
    @ObservationIgnored private var commentsToken: String?
    @ObservationIgnored private var replyTokens: [String: String] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "Watch")

    init(videoId: String, client: InnerTubeClient, isSignedIn: @escaping () -> Bool) {
        self.videoId = videoId
        self.client = client
        self.isSignedIn = isSignedIn
    }

    /// The count to display for the current like state.
    /// From Return YouTube Dislike; nil until loaded or when the setting is off.
    private(set) var dislikeCount: Int?

    func loadDislikes() async {
        dislikeCount = await ReturnDislikeAPI.dislikes(for: videoId)
    }

    /// The count with your own dislike counted (the API only sees votes from its own users).
    var displayedDislikeCount: String? {
        guard var count = dislikeCount else { return nil }
        if likeStatus == .dislike && details?.likeStatus != .dislike { count += 1 }
        if likeStatus != .dislike && details?.likeStatus == .dislike { count = max(0, count - 1) }
        return count.formatted(.number.notation(.compactName))
    }

    var displayedLikeCount: String? {
        guard let d = details else { return nil }
        if likeStatus == .like { return d.likeCountWhenLiked ?? d.likeCount }
        return d.likeCount
    }

    func load() async {
        async let playlistsLoad: Void = loadPlaylists()
        do {
            let json = try await client.next(videoId: videoId)
            guard let d = WatchParser.details(from: json, videoId: videoId) else {
                loadError = "Couldn't read this video's page."
                return
            }
            details = d
            likeStatus = d.likeStatus
            isSubscribed = d.isSubscribed
            bell = d.bell
            related = d.related
            relatedToken = d.relatedContinuation
            relatedChips = d.relatedChips
            commentsToken = d.commentsToken
            if let token = d.liveChatToken {
                let chat = LiveChatModel(client: client)
                liveChat = chat
                chat.start(token: token)
            }
            MemoryRelief.soon()
        } catch {
            loadError = error.localizedDescription
        }
        await playlistsLoad
    }

    // MARK: - Likes

    func toggleLike() { setLike(likeStatus == .like ? .none : .like) }
    func toggleDislike() { setLike(likeStatus == .dislike ? .none : .dislike) }

    private func setLike(_ status: LikeStatus) {
        guard signedIn else { actionError = "Sign in to like videos."; return }
        let previous = likeStatus
        likeStatus = status
        Task {
            do {
                switch status {
                case .like: try await client.like(videoId)
                case .dislike: try await client.dislike(videoId)
                case .none: try await client.removeLike(videoId)
                }
            } catch {
                likeStatus = previous
                actionError = "Couldn't update your rating: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Subscription

    func setSubscribed(_ subscribed: Bool) {
        guard signedIn else { actionError = "Sign in to subscribe."; return }
        guard let channelId = details?.channel?.id else { return }
        let previous = (isSubscribed, bell)
        isSubscribed = subscribed
        bell = subscribed ? ChannelBell.afterSubscribing(to: channelId) : nil
        Task {
            do {
                if subscribed { try await client.subscribe(to: channelId) } else { try await client.unsubscribe(from: channelId) }
            } catch {
                (isSubscribed, bell) = previous
                actionError = "Couldn't update your subscription: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Notification bell

    func setBell(_ setting: BellSetting) {
        guard let current = bell, let params = current.params[setting], current.setting != setting else { return }
        bell?.setting = setting
        Task {
            do {
                try await client.setChannelNotifications(params: params)
            } catch {
                bell?.setting = current.setting
                actionError = "Couldn't change notifications: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Playlists

    func loadPlaylists() async {
        guard signedIn else { return }
        do {
            playlists = WatchParser.playlistOptions(from: try await client.playlistOptions(for: videoId))
        } catch {
            log.error("Playlist options failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func toggleWatchLater() {
        if let wl = playlists.first(where: \.isWatchLater) {
            setPlaylist(wl.id, !wl.containsVideo)
        } else if signedIn {
            // Menu not loaded yet; Watch Later always exists.
            playlists.insert(PlaylistOption(id: "WL", title: "Watch later", containsVideo: false, isPrivate: true), at: 0)
            setPlaylist("WL", true)
        } else {
            actionError = "Sign in to use Watch Later."
        }
    }

    func setPlaylist(_ id: String, _ included: Bool) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].containsVideo = included
        Task {
            do {
                try await client.setVideo(videoId, inPlaylist: id, included)
            } catch {
                if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].containsVideo = !included }
                actionError = "Couldn't update the playlist: \(error.localizedDescription)"
            }
        }
    }

    func dismissError() { actionError = nil }

    // MARK: - Related

    // MARK: Related filters

    private(set) var relatedChips: [RelatedChip] = []
    private(set) var selectedRelatedChip: String?
    /// The list the page came with, for going back to "All" without a request.
    @ObservationIgnored private var allRelated: (videos: [Video], token: String?)?

    func selectRelatedChip(_ chip: RelatedChip) async {
        guard chip.title != (selectedRelatedChip ?? relatedChips.first?.title), !isLoadingRelated else { return }
        if allRelated == nil { allRelated = (related, relatedToken) }
        selectedRelatedChip = chip.title
        guard let token = chip.token else {
            related = allRelated?.videos ?? related
            relatedToken = allRelated?.token
            return
        }
        isLoadingRelated = true
        related = []
        defer { isLoadingRelated = false }
        do {
            let page = WatchParser.relatedPage(from: try await client.next(continuation: token))
            // A slower response for a chip that's no longer selected is dropped.
            guard selectedRelatedChip == chip.title else { return }
            related = page.videos.filter { $0.id != videoId }
            relatedToken = page.continuation
            MemoryRelief.soon()
        } catch {
            log.error("Related chip failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadMoreRelated() async {
        guard let token = relatedToken, !isLoadingRelated else { return }
        isLoadingRelated = true
        defer { isLoadingRelated = false }
        do {
            let page = WatchParser.relatedPage(from: try await client.next(continuation: token))
            let known = Set(related.map(\.id))
            related += page.videos.filter { !known.contains($0.id) && $0.id != videoId }
            relatedToken = page.continuation
        } catch {
            log.error("Related page failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var canLoadMoreRelated: Bool { relatedToken != nil }

    // MARK: - Comments

    var hasComments: Bool { commentsToken != nil || !comments.isEmpty }
    var canLoadMoreComments: Bool { commentsToken != nil }

    func loadMoreComments() async {
        guard let token = commentsToken, !isLoadingComments else { return }
        isLoadingComments = true
        defer { isLoadingComments = false; commentsLoaded = true }
        do {
            let page = WatchParser.comments(from: try await client.next(continuation: token))
            let known = Set(comments.map(\.id))
            comments += page.comments.filter { !known.contains($0.id) }
            commentsToken = page.continuation
            if let p = page.createParams { createCommentParams = p }
        } catch {
            log.error("Comments failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadReplies(for comment: Comment) async {
        guard let token = replyTokens[comment.id] ?? (replies[comment.id] == nil ? comment.repliesToken : nil),
              !loadingReplies.contains(comment.id) else { return }
        loadingReplies.insert(comment.id)
        defer { loadingReplies.remove(comment.id) }
        do {
            let page = WatchParser.comments(from: try await client.next(continuation: token))
            // A reply you just posted can come back in a later page; show it once.
            let known = Set(replies[comment.id]?.map(\.id) ?? [])
            replies[comment.id, default: []] += page.comments.filter { !known.contains($0.id) }
            replyTokens[comment.id] = page.continuation
        } catch {
            log.error("Replies failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func hasMoreReplies(_ comment: Comment) -> Bool {
        replies[comment.id] == nil ? comment.repliesToken != nil : replyTokens[comment.id] != nil
    }

    func hideReplies(for comment: Comment) {
        replies[comment.id] = nil
        replyTokens[comment.id] = nil
    }

    // MARK: - Writing comments

    /// Posts a top-level comment and shows it first. Returns false (with `actionError` set) on failure.
    func postComment(_ text: String) async -> Bool {
        guard let params = createCommentParams else { return false }
        do {
            let json = try await client.createComment(text, params: params)
            comments.insert(WatchParser.postedComment(from: json) ?? localComment(text), at: 0)
            return true
        } catch {
            actionError = "Couldn't post your comment: \(error.localizedDescription)"
            return false
        }
    }

    /// Replies to `comment`; replies to a reply land in the same thread (`threadId`).
    func reply(to comment: Comment, inThread threadId: String, text: String) async -> Bool {
        guard let params = comment.actions.reply else { return false }
        do {
            let json = try await client.createReply(text, params: params)
            let posted = WatchParser.postedComment(from: json) ?? localComment(text)
            if replies[threadId] == nil, let thread = comments.first(where: { $0.id == threadId }) {
                // Keep the thread's other replies reachable through "Show more replies".
                replyTokens[threadId] = thread.repliesToken
            }
            replies[threadId, default: []].append(posted)
            if let i = comments.firstIndex(where: { $0.id == threadId }) { comments[i].replyCount += 1 }
            return true
        } catch {
            actionError = "Couldn't post your reply: \(error.localizedDescription)"
            return false
        }
    }

    func edit(_ comment: Comment, text: String) async -> Bool {
        guard let params = comment.actions.edit else { return false }
        do {
            try await client.updateComment(text, params: params, isReply: comment.actions.editIsReply)
            updateComment(comment.id) { $0.text = text }
            return true
        } catch {
            actionError = "Couldn't edit your comment: \(error.localizedDescription)"
            return false
        }
    }

    func delete(_ comment: Comment, inThread threadId: String?) {
        guard let action = comment.actions.delete else { return }
        // Optimistic: put it back where it was if YouTube refuses.
        let topIndex = comments.firstIndex { $0.id == comment.id }
        let replyIndex = threadId.flatMap { t in replies[t]?.firstIndex { $0.id == comment.id } }
        if let topIndex { comments.remove(at: topIndex) }
        if let threadId, let replyIndex {
            replies[threadId]?.remove(at: replyIndex)
            if let i = comments.firstIndex(where: { $0.id == threadId }) { comments[i].replyCount -= 1 }
        }
        Task {
            do {
                try await client.performCommentAction(action)
            } catch {
                if let topIndex { comments.insert(comment, at: min(topIndex, comments.count)) }
                if let threadId, let replyIndex {
                    replies[threadId]?.insert(comment, at: min(replyIndex, replies[threadId]?.count ?? 0))
                    if let i = comments.firstIndex(where: { $0.id == threadId }) { comments[i].replyCount += 1 }
                }
                actionError = "Couldn't delete your comment: \(error.localizedDescription)"
            }
        }
    }

    func toggleLike(_ comment: Comment) {
        guard signedIn else { actionError = "Sign in to like comments."; return }
        let liked = !comment.isLiked
        guard let action = liked ? comment.actions.like : comment.actions.unlike else { return }
        updateComment(comment.id) { $0.isLiked = liked }
        Task {
            do {
                try await client.performCommentAction(action)
            } catch {
                updateComment(comment.id) { $0.isLiked = !liked }
                actionError = "Couldn't update your like: \(error.localizedDescription)"
            }
        }
    }

    /// Applies `change` to the comment wherever it is shown (top level or a reply).
    private func updateComment(_ id: String, _ change: (inout Comment) -> Void) {
        if let i = comments.firstIndex(where: { $0.id == id }) { change(&comments[i]) }
        for (thread, list) in replies {
            if let i = list.firstIndex(where: { $0.id == id }) { change(&replies[thread]![i]) }
        }
    }

    /// Shown when a post succeeded but its response couldn't be read. It has no edit or
    /// delete actions until the comments reload.
    private func localComment(_ text: String) -> Comment {
        log.warning("Couldn't read the posted comment from the response")
        return Comment(id: UUID().uuidString, author: accountName?() ?? "You", avatar: accountPhoto?(),
                       text: text, published: "just now", replyCount: 0, isCreator: false, isVerified: false)
    }

    /// The signed-in account, for comments shown before YouTube returns them.
    @ObservationIgnored var accountName: (() -> String?)?
    @ObservationIgnored var accountPhoto: (() -> URL?)?
}

