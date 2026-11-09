import Foundation

nonisolated struct Thumbnail: Hashable, Sendable {
    let url: URL
    let width: Int
    let height: Int
}

/// A video as shown in a feed, search result or related list.
nonisolated struct Video: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case video, live, upcoming, short
    }

    let id: String
    var title: String
    var kind: Kind = .video
    var channelName: String?
    var channelId: String?
    var channelAvatar: URL?
    /// Formatted length, e.g. "12:04". Nil for live streams and most Shorts.
    var duration: String?
    /// Formatted view count, e.g. "1.2M views" or "3.4K watching".
    var viewCount: String?
    /// Relative publish date, e.g. "2 days ago".
    var published: String?
    var thumbnails: [Thumbnail] = []
    /// 0...1 when YouTube reports the signed-in user has partially watched it.
    var watchedFraction: Double?
    /// Only the channel's paying members can watch it.
    var isMembersOnly = false
    /// Feedback tokens from the card's menu, for tuning recommendations (home and related only).
    var notInterestedToken: String?
    var dontRecommendChannelToken: String?

    /// Smallest thumbnail at least `minWidth` pixels wide, else the largest available.
    /// Falls back to YouTube's predictable `mqdefault` (320×180) URL.
    func thumbnail(minWidth: Int) -> URL {
        let sorted = thumbnails.sorted { $0.width < $1.width }
        if let fit = sorted.first(where: { $0.width >= minWidth }) ?? sorted.last {
            return fit.url
        }
        return URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")!
    }
}
