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

        // The button's own flag, else the subscription entity the newer layout links to it.
        let subscribed = secondary.first("subscribeButtonRenderer")?["subscribed"].bool
            ?? json["frameworkUpdates"].first("subscriptionStateEntity")?["subscribed"].bool
            ?? false

        return WatchDetails(
            videoId: videoId,
            title: title,
            viewCount: views["viewCount"].text,
            shortViewCount: views["shortViewCount"].text,
            publishedRelative: primary["relativeDateText"].text,
            publishedDate: primary["dateText"].text,
            description: expandedDescription(secondary["attributedDescription"])
                ?? secondary["description"].text ?? "",
            channel: channel,
            isSubscribed: subscribed,
            bell: subscribed ? NotificationParser.bell(in: secondary) : nil,
            likeCount: likeTitle.flatMap { $0.first?.isNumber == true ? $0 : nil },
            likeCountWhenLiked: likedTitle.flatMap { $0.first?.isNumber == true ? $0 : nil },
            likeStatus: status,
            related: related,
            relatedContinuation: relatedToken,
            commentsToken: commentsToken,
            liveChatToken: LiveChatParser.initialToken(from: json)
        )
    }

    /// The description with every link written out in full. YouTube shortens link text
    /// ("/ discord", "https://studio.blender.org/projects/b...") and keeps the real target in
    /// `commandRuns`; shown as-is, those were plain text or links to the truncated address.
    private static func expandedDescription(_ description: JSON) -> String? {
        guard let content = description["content"].string else { return nil }
        var text = content as NSString
        // From the end, so earlier ranges stay valid. Indices are UTF-16 offsets, like NSString's.
        let runs = description["commandRuns"].array.sorted { ($0["startIndex"].int ?? 0) > ($1["startIndex"].int ?? 0) }
        for run in runs {
            guard let start = run["startIndex"].int, let length = run["length"].int,
                  start >= 0, length > 0, start + length <= text.length,
                  let link = run.first("urlEndpoint")?["url"].string,
                  let target = realTarget(of: link) else { continue }
            let range = NSRange(location: start, length: length)
            if text.substring(with: range) == target { continue }
            text = text.replacingCharacters(in: range, with: target) as NSString
        }
        return text as String
    }

    /// YouTube wraps outside links in its redirect page; the destination is its `q` parameter.
    private static func realTarget(of link: String) -> String? {
        guard let components = URLComponents(string: link) else { return nil }
        if components.path == "/redirect", let q = components.queryItems?.first(where: { $0.name == "q" })?.value {
            return q
        }
        return link
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
        let entities = CommentEntities(json)
        var comments: [Comment] = []
        let items = continuationItems(json)
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
            if let c = comment(vm: vm, thread: thread, entities: entities) { comments.append(c) }
        }
        // The page's own "load more" is the trailing continuation item.
        let token = items.last.flatMap { $0["continuationItemRenderer"].isNull ? nil : $0["continuationItemRenderer"].first("token")?.string }
        // The composer sits in the comments header, which only the first page carries.
        let create = json["onResponseReceivedEndpoints"].first("commentsHeaderRenderer")?.first("createCommentParams")?.string
        return CommentsPage(comments: comments, continuation: token, createParams: create)
    }

    /// The comment a `create_comment` / `create_comment_reply` response returns, in the same
    /// entity format as comment pages (so it comes with its own edit/delete actions).
    static func postedComment(from json: JSON) -> Comment? {
        let entities = CommentEntities(json)
        let actions = json["actions"]
        if let thread = actions.first("commentThreadRenderer") {
            return comment(vm: thread["commentViewModel"]["commentViewModel"], thread: thread, entities: entities)
        }
        guard let vm = actions.first("commentViewModel") else { return nil }
        return comment(vm: vm["commentViewModel"].isNull ? vm : vm["commentViewModel"], thread: .null, entities: entities)
    }

    /// Fails with YouTube's message when an account action response reports a failure.
    static func actionFailure(in json: JSON) -> String? {
        let status = json["actionResult"]["status"].string ?? json["actionResults"][0]["status"].string
        guard let status, status != "STATUS_SUCCEEDED" else { return nil }
        return json.first("feedback")?.text ?? json["actionResult"].first("text")?.text ?? "YouTube refused the request."
    }

    /// Comment data arrives as entities in frameworkUpdates, linked from each view model by key.
    private struct CommentEntities {
        var comments: [String: JSON] = [:]
        /// GIF attachments.
        var surfaces: [String: JSON] = [:]
        /// Like / reply / menu commands.
        var toolbarSurfaces: [String: JSON] = [:]
        /// Whether you liked it.
        var toolbarStates: [String: JSON] = [:]

        init(_ json: JSON) {
            for m in json["frameworkUpdates"]["entityBatchUpdate"]["mutations"].array {
                guard let key = m["entityKey"].string else { continue }
                let p = m["payload"]
                if !p["commentEntityPayload"].isNull { comments[key] = p["commentEntityPayload"] }
                if !p["commentSurfaceEntityPayload"].isNull { surfaces[key] = p["commentSurfaceEntityPayload"] }
                if !p["engagementToolbarSurfaceEntityPayload"].isNull { toolbarSurfaces[key] = p["engagementToolbarSurfaceEntityPayload"] }
                if !p["engagementToolbarStateEntityPayload"].isNull { toolbarStates[key] = p["engagementToolbarStateEntityPayload"] }
            }
        }
    }

    private static func comment(vm: JSON, thread: JSON, entities: CommentEntities) -> Comment? {
        guard let key = vm["commentKey"].string, let e = entities.comments[key],
              let id = e["properties"]["commentId"].string else { return nil }
        let author = e["author"], props = e["properties"], toolbar = e["toolbar"]
        let surface = vm["commentSurfaceKey"].string.flatMap { entities.surfaces[$0] } ?? .null
        let commands = vm["toolbarSurfaceKey"].string.flatMap { entities.toolbarSurfaces[$0] } ?? .null
        let state = vm["toolbarStateKey"].string.flatMap { entities.toolbarStates[$0] } ?? .null
        func nonBlank(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        return Comment(
            id: id,
            author: author["displayName"].string ?? "",
            authorChannelId: author["channelId"].string,
            avatar: VideoParser.url(author["avatarThumbnailUrl"].string),
            text: props["content"]["content"].string ?? "",
            published: props["publishedTime"].string,
            likeCount: nonBlank(toolbar["likeCountNotliked"].string),
            replyCount: Int(toolbar["replyCount"].string ?? "") ?? toolbar["replyCount"].int ?? 0,
            isCreator: author["isCreator"].bool ?? false,
            isVerified: author["isVerified"].bool ?? false,
            repliesToken: thread["replies"].first("token")?.string,
            gif: surface.isNull ? nil : gif(from: surface),
            isLiked: state["likeState"].string == "TOOLBAR_LIKE_STATE_LIKED",
            likeCountLiked: nonBlank(toolbar["likeCountLiked"].string),
            actions: actions(commands: commands, surface: surface)
        )
    }

    /// Reply and like come from the toolbar's commands; edit and delete appear in the
    /// action menu of your own comments. Searched recursively: these menus change often.
    private static func actions(commands: JSON, surface: JSON) -> CommentActions {
        var a = CommentActions()
        a.reply = commands["replyCommand"].first("createReplyParams")?.string
        a.like = commands["likeCommand"].first("performCommentActionEndpoint")?["action"].string
        a.unlike = commands["unlikeCommand"].first("performCommentActionEndpoint")?["action"].string
        let menus = [commands["menuCommand"], surface]
        for menu in menus {
            if a.edit == nil, let p = menu.first("updateCommentParams")?.string { a.edit = p }
            if a.edit == nil, let p = menu.first("updateReplyParams")?.string { a.edit = p; a.editIsReply = true }
            if a.delete == nil {
                let items = menu.all("menuServiceItemRenderer") + menu.all("menuNavigationItemRenderer")
                let deleteItem = items.first {
                    $0["text"].text?.lowercased() == "delete" || $0["icon"]["iconType"].string == "DELETE"
                }
                a.delete = deleteItem?.first("performCommentActionEndpoint")?["action"].string
            }
        }
        return a
    }

    private static func gif(from surface: JSON) -> CommentGIF? {
        let a = surface["imageAttachmentViewModel"]["commentImageAttachmentViewModel"]
        guard let src = a["image"]["sources"].array.first,
              let url = VideoParser.url(src["url"].string) else { return nil }
        let w = a["width"].double ?? src["width"].double ?? 1, h = a["height"].double ?? src["height"].double ?? 1
        return CommentGIF(url: url, width: w, height: h)
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
