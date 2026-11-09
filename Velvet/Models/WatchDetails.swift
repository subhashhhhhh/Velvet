import Foundation

nonisolated enum LikeStatus: String, Sendable {
    case like = "LIKE", dislike = "DISLIKE", none = "INDIFFERENT"
}

nonisolated struct ChannelInfo: Hashable, Sendable {
    var id: String?
    var name: String
    var avatar: URL?
    var subscribers: String?
    /// e.g. "/@Formula1"
    var handlePath: String?
}

/// Everything on the watch page besides the stream: from InnerTube's `next` endpoint.
nonisolated struct WatchDetails: Sendable {
    let videoId: String
    var title: String
    var viewCount: String?
    var shortViewCount: String?
    var publishedRelative: String?
    var publishedDate: String?
    var description: String
    var channel: ChannelInfo?
    /// The signed-in user is subscribed to the channel.
    var isSubscribed = false
    /// The channel's notification bell (subscribed channels only).
    var bell: ChannelBell?
    /// Formatted like count as shown when you haven't liked it, e.g. "68K".
    var likeCount: String?
    /// The count YouTube shows once you've liked it (it's preformatted, so we can't add 1 ourselves).
    var likeCountWhenLiked: String?
    var likeStatus: LikeStatus
    var related: [Video]
    var relatedContinuation: String?
    /// Filters above the related videos (All, From the series, a topic, For you, Watched).
    var relatedChips: [RelatedChip] = []
    var commentsToken: String?
    /// "Top chat" token when the video is a live stream with chat.
    var liveChatToken: String?
}

nonisolated struct Comment: Identifiable, Hashable, Sendable {
    let id: String
    var author: String
    var authorChannelId: String?
    var avatar: URL?
    var text: String
    var published: String?
    var likeCount: String?
    var replyCount: Int
    var isCreator: Bool
    var isVerified: Bool
    var repliesToken: String?
    /// An attached GIF (YouTube serves them as animated WebP).
    var gif: CommentGIF?
    /// The signed-in user liked it.
    var isLiked = false
    /// The count YouTube shows once you've liked it (preformatted, like video likes).
    var likeCountLiked: String?
    /// What the signed-in user may do with it; empty when signed out.
    var actions = CommentActions()
}

/// Opaque InnerTube parameters for the actions YouTube offers on a comment.
nonisolated struct CommentActions: Hashable, Sendable {
    var reply: String?
    var like: String?
    var unlike: String?
    /// Only on your own comments.
    var edit: String?
    /// Replies are edited through a separate endpoint.
    var editIsReply = false
    var delete: String?
}

nonisolated struct CommentGIF: Hashable, Sendable {
    let url: URL
    let width: Double
    let height: Double
}

nonisolated struct CommentsPage: Sendable {
    var comments: [Comment]
    var continuation: String?
    /// Parameters for posting a new top-level comment (first page, signed in).
    var createParams: String?
}

nonisolated struct PlaylistOption: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var containsVideo: Bool
    var isPrivate: Bool

    var isWatchLater: Bool { id == "WL" }
}

/// A related-videos filter. "All" has no token: it restores the list the page came with.
nonisolated struct RelatedChip: Hashable, Sendable, Identifiable {
    var id: String { title }
    let title: String
    let token: String?
}
