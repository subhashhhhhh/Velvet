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

    var isInWatchLater: Bool { playlists.first(where: \.isWatchLater)?.containsVideo ?? false }

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
            related = d.related
            relatedToken = d.relatedContinuation
            commentsToken = d.commentsToken
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
            replies[comment.id, default: []] += page.comments
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
}
