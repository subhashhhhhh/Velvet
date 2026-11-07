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
    /// Formatted like count, e.g. "68K".
    var likeCount: String?
    var likeStatus: LikeStatus
    var related: [Video]
    var relatedContinuation: String?
    var commentsToken: String?
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
}

nonisolated struct CommentsPage: Sendable {
    var comments: [Comment]
    var continuation: String?
}

nonisolated struct PlaylistOption: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var containsVideo: Bool
    var isPrivate: Bool

    var isWatchLater: Bool { id == "WL" }
}
