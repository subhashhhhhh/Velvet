import Foundation

/// Parses the watch page (`next`), comment pages and the add-to-playlist menu.
nonisolated enum WatchParser {
    static func details(from json: JSON, videoId: String) -> WatchDetails? {
        let results = json["contents"]["twoColumnWatchNextResults"]
        guard let primary = results.first("videoPrimaryInfoRenderer"),
              let title = primary["title"].text else { return nil }
        let secondary = results.first("videoSecondaryInfoRenderer") ?? .null
        let owner = secondary.first("videoOwnerRenderer") ?? .null
        let views = primary["viewCount"]["videoViewCountRenderer"]

        let channel = owner["title"].text.map { name in
            ChannelInfo(
                id: owner["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
                name: name,
                avatar: VideoParser.thumbnails(owner["thumbnail"]["thumbnails"]).max { $0.width < $1.width }?.url,
                subscribers: owner["subscriberCountText"].text,
                handlePath: owner["navigationEndpoint"]["browseEndpoint"]["canonicalBaseUrl"].string
            )
        }

        let likeVM = primary.first("segmentedLikeDislikeButtonViewModel")?["likeButtonViewModel"]["likeButtonViewModel"] ?? .null
        let likeTitle = likeVM.first("defaultButtonViewModel")?["buttonViewModel"]["title"].string
        let likedTitle = likeVM.first("toggledButtonViewModel")?["buttonViewModel"]["title"].string
        let status = likeVM["likeStatusEntity"]["likeStatus"].string.flatMap(LikeStatus.init(rawValue:)) ?? .none

        // Related videos live in the secondary column; their "load more" token sits at its end.
        let secondaryColumn = results["secondaryResults"]
        let related = VideoParser.videos(in: secondaryColumn).filter { $0.id != videoId }
        let relatedToken = secondaryColumn.all("continuationItemRenderer")
            .compactMap { $0["continuationEndpoint"]["continuationCommand"]["token"].string }.last

        let commentsSection = results["results"]["results"]["contents"].array
            .map { $0["itemSectionRenderer"] }
            .first { $0["sectionIdentifier"].string == "comment-item-section" }
        let commentsToken = commentsSection?.first("continuationCommand")?["token"].string

        return WatchDetails(
            videoId: videoId,
            title: title,
            viewCount: views["viewCount"].text,
            shortViewCount: views["shortViewCount"].text,
            publishedRelative: primary["relativeDateText"].text,
            publishedDate: primary["dateText"].text,
            description: secondary["attributedDescription"]["content"].string
                ?? secondary["description"].text ?? "",
            channel: channel,
            likeCount: likeTitle.flatMap { $0.first?.isNumber == true ? $0 : nil },
            likeCountWhenLiked: likedTitle.flatMap { $0.first?.isNumber == true ? $0 : nil },
            likeStatus: status,
            related: related,
            relatedContinuation: relatedToken,
            commentsToken: commentsToken,
            liveChatToken: LiveChatParser.initialToken(from: json)
        )
    }

    /// Related videos from a `next` continuation (scrolling the related column).
    static func relatedPage(from json: JSON) -> (videos: [Video], continuation: String?) {
        let items = continuationItems(json)
        let videos = VideoParser.videos(in: .array(items))
        let token = items.last?["continuationItemRenderer"].first("token")?.string
        return (videos, token)
    }

    /// Comments (top-level or replies) from a `next` continuation response.
    static func comments(from json: JSON) -> CommentsPage {
        // Comment bodies are entities in frameworkUpdates, linked by `commentKey`.
        var entities: [String: JSON] = [:]
        for m in json["frameworkUpdates"]["entityBatchUpdate"]["mutations"].array {
            if let key = m["entityKey"].string, !m["payload"]["commentEntityPayload"].isNull {
                entities[key] = m["payload"]["commentEntityPayload"]
            }
        }

        let items = continuationItems(json)
        var comments: [Comment] = []
        for item in items {
            let thread = item["commentThreadRenderer"]
            let vm: JSON
            if !thread.isNull {
                vm = thread["commentViewModel"]["commentViewModel"]
            } else if !item["commentViewModel"].isNull {
                vm = item["commentViewModel"] // reply pages list view models directly
            } else {
                continue
            }
            guard let key = vm["commentKey"].string, let e = entities[key],
                  let id = e["properties"]["commentId"].string else { continue }
            let author = e["author"], props = e["properties"], toolbar = e["toolbar"]
            comments.append(Comment(
                id: id,
                author: author["displayName"].string ?? "",
                authorChannelId: author["channelId"].string,
                avatar: VideoParser.url(author["avatarThumbnailUrl"].string),
                text: props["content"]["content"].string ?? "",
                published: props["publishedTime"].string,
                likeCount: toolbar["likeCountNotliked"].string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
                replyCount: Int(toolbar["replyCount"].string ?? "") ?? toolbar["replyCount"].int ?? 0,
                isCreator: author["isCreator"].bool ?? false,
                isVerified: author["isVerified"].bool ?? false,
                repliesToken: thread["replies"].first("token")?.string
            ))
        }
        // The page's own "load more" is the trailing continuation item.
        let token = items.last.flatMap { $0["continuationItemRenderer"].isNull ? nil : $0["continuationItemRenderer"].first("token")?.string }
        return CommentsPage(comments: comments, continuation: token)
    }

    /// Items appended/reloaded by a continuation response.
    private static func continuationItems(_ json: JSON) -> [JSON] {
        var items: [JSON] = []
        for endpoint in json["onResponseReceivedEndpoints"].array {
            let reload = endpoint["reloadContinuationItemsCommand"]["continuationItems"].array
            let append = endpoint["appendContinuationItemsAction"]["continuationItems"].array
            // The comments header arrives in its own reload command; only keep item lists.
            items += reload.filter { $0["commentsHeaderRenderer"].isNull }
            items += append
        }
        return items
    }

    static func playlistOptions(from json: JSON) -> [PlaylistOption] {
        json.all("playlistAddToOptionRenderer").compactMap { o in
            guard let id = o["playlistId"].string, let title = o["title"].text else { return nil }
            return PlaylistOption(
                id: id,
                title: title,
                containsVideo: o["containsSelectedVideos"].string == "ALL",
                isPrivate: o["privacy"].string == "PRIVATE"
            )
        }
    }
}
