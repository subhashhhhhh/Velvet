import Foundation

/// Extracts `Video`s from any InnerTube response.
///
/// YouTube currently mixes three item formats:
/// - `videoRenderer` (+ grid/compact variants): search results, older surfaces
/// - `lockupViewModel`: home feed, related videos, most new surfaces
/// - `shortsLockupViewModel` / `reelItemRenderer`: Shorts shelves
///
/// Instead of following exact paths through the page layout (which changes
/// often), we walk the whole tree and parse every item we recognise.
nonisolated enum VideoParser {
    private static let rendererKeys: Set<String> = [
        "videoRenderer", "gridVideoRenderer", "compactVideoRenderer",
        "playlistVideoRenderer", "lockupViewModel",
        "shortsLockupViewModel", "reelItemRenderer",
    ]

    /// Containers that hold promotions rather than recommendations: YouTube's own "featured"
    /// campaign shelves (e.g. a film launch) and paid ad slots. Their cards would otherwise
    /// be flattened into the grid like ordinary videos.
    static let promotionKeys: Set<String> = ["brandVideoShelfRenderer", "adSlotRenderer"]

    /// Home's "Breaking news" shelf: several news clips about one story. Its title is in the
    /// user's language, so it is found by its layout: of the home shelves, only the news
    /// shelf has a headline under its title (`subtitle`). Shorts shelves carry an icon.
    static func isNewsShelf(_ key: String, _ value: JSON) -> Bool {
        key == "richShelfRenderer" && !value["subtitle"].isNull && value["icon"].isNull
    }

    /// All videos in `json`, in document order, de-duplicated by id. Containers named in
    /// `skipping` are not searched, and neither is the news shelf when `skippingNews` is set.
    static func videos(in json: JSON, skipping: Set<String> = [], skippingNews: Bool = false) -> [Video] {
        var out: [Video] = []
        var seen = Set<String>()
        let skip: (String, JSON) -> Bool = { key, value in
            skipping.contains(key) || (skippingNews && isNewsShelf(key, value))
        }
        walk(json, skip: skip) { key, value in
            guard let video = parse(key: key, value) else { return }
            if seen.insert(video.id).inserted { out.append(video) }
        }
        return out
    }

    /// Continuation tokens ("load more") found in `json`, in document order.
    static func continuations(in json: JSON) -> [String] {
        json.all("continuationItemRenderer").compactMap {
            $0["continuationEndpoint"]["continuationCommand"]["token"].string
                ?? $0.first("token")?.string
        }
    }

    static func parse(key: String, _ r: JSON) -> Video? {
        switch key {
        case "videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "playlistVideoRenderer":
            return parseVideoRenderer(r)
        case "lockupViewModel":
            return parseLockup(r)
        case "shortsLockupViewModel":
            return parseShortsLockup(r)
        case "reelItemRenderer":
            return parseReelItem(r)
        default:
            return nil
        }
    }

    // MARK: - Tree walk

    /// Visits recognised renderers depth-first, without descending into them
    /// (so a video's own menus/endpoints are never mistaken for other videos).
    private static func walk(_ json: JSON, skip: (String, JSON) -> Bool, _ visit: (String, JSON) -> Void) {
        switch json {
        case .object(let o):
            for key in o.keys.sorted() {
                let value = o[key]!
                if skip(key, value) { continue }
                if rendererKeys.contains(key) {
                    visit(key, value)
                } else {
                    walk(value, skip: skip, visit)
                }
            }
        case .array(let a):
            for v in a { walk(v, skip: skip, visit) }
        default:
            break
        }
    }

    // MARK: - videoRenderer

    private static func parseVideoRenderer(_ r: JSON) -> Video? {
        guard let id = r["videoId"].string,
              let title = r["title"].text ?? r["headline"].text else { return nil }

        let owner = r["ownerText"].isNull ? (r["longBylineText"].isNull ? r["shortBylineText"] : r["longBylineText"]) : r["ownerText"]
        let badges = r["badges"].array.compactMap { $0["metadataBadgeRenderer"]["style"].string }
        let overlayStyles = r["thumbnailOverlays"].array.compactMap {
            $0["thumbnailOverlayTimeStatusRenderer"]["style"].string
        }
        let viewText = r["viewCountText"].text ?? r["shortViewCountText"].text

        var kind = Video.Kind.video
        if badges.contains("BADGE_STYLE_TYPE_LIVE_NOW") || overlayStyles.contains("LIVE")
            || (r["lengthText"].isNull && viewText?.contains("watching") == true) {
            kind = .live
        } else if !r["upcomingEventData"].isNull || overlayStyles.contains("UPCOMING") {
            kind = .upcoming
        } else if overlayStyles.contains("SHORTS") {
            kind = .short
        }

        let resume = r["thumbnailOverlays"].array
            .compactMap { $0["thumbnailOverlayResumePlaybackRenderer"]["percentDurationWatched"].double }
            .first

        var video = Video(
            id: id,
            title: title,
            kind: kind,
            channelName: owner.text,
            channelId: owner["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
            channelAvatar: url(r["channelThumbnailSupportedRenderers"]["channelThumbnailWithLinkRenderer"]["thumbnail"]["thumbnails"][0]["url"].string
                ?? r["channelThumbnail"]["thumbnails"][0]["url"].string),
            duration: r["lengthText"].text,
            viewCount: viewText,
            published: r["publishedTimeText"].text,
            thumbnails: thumbnails(r["thumbnail"]["thumbnails"]),
            watchedFraction: resume.map { $0 / 100 }
        )
        video.isMembersOnly = badges.contains("BADGE_STYLE_TYPE_MEMBERS_ONLY")
        video.channelHandle = handle(in: owner)
        applyFeedback(r["menu"].all("menuServiceItemRenderer"), to: &video)
        return video
    }

    /// The channel's "@handle" from its link ("/@name", percent-encoded for non-ASCII names).
    static func handle(in json: JSON) -> String? {
        guard let path = json.first("canonicalBaseUrl")?.string ?? json.first("url")?.string,
              path.hasPrefix("/@") else { return nil }
        let raw = String(path.dropFirst())
        return (raw.removingPercentEncoding ?? raw).lowercased()
    }

    // MARK: - lockupViewModel

    private static func parseLockup(_ r: JSON) -> Video? {
        guard let id = r["contentId"].string else { return nil }
        let type = r["contentType"].string ?? ""
        // Skip playlists, mixes, channels etc.; they get their own models later.
        guard type.isEmpty || type == "LOCKUP_CONTENT_TYPE_VIDEO" else { return nil }

        let meta = r["metadata"]["lockupMetadataViewModel"]
        guard let title = meta["title"].text else { return nil }

        let image = r["contentImage"]["thumbnailViewModel"]
        let badges = image.all("thumbnailBadgeViewModel")
        let badgeTexts = badges.compactMap { $0["text"].string }
        let badgeStyles = badges.compactMap { $0["badgeStyle"].string }

        // Metadata rows: [channel] then [views, age] — but the order varies by surface,
        // so classify parts by what they say rather than where they are.
        let rows = meta["metadata"]["contentMetadataViewModel"]["metadataRows"].array
        var channelName: String?
        var viewCount: String?
        var published: String?
        var isLive = false
        for (rowIndex, row) in rows.enumerated() {
            for part in row["metadataParts"].array {
                guard let text = part["text"]["content"].string, !text.isEmpty else { continue }
                let label = (part["accessibilityLabel"].string ?? text).lowercased()
                if label.contains("watching") {
                    viewCount = text.lowercased().contains("watching") ? text : "\(text) watching"
                    isLive = true
                } else if label.contains("view") {
                    viewCount = text.lowercased().contains("view") ? text : "\(text) views"
                } else if label.contains("ago") || label.contains("streamed") || label.contains("premiere")
                            || label.contains("scheduled") {
                    published = text
                } else if rowIndex == 0 && channelName == nil {
                    channelName = text
                }
            }
        }

        let avatar = meta["image"]["decoratedAvatarViewModel"]
        let channelId = avatar.first("browseEndpoint")?["browseId"].string
            ?? meta["metadata"].first("browseEndpoint")?["browseId"].string

        var kind = Video.Kind.video
        if isLive || badgeStyles.contains(where: { $0.contains("LIVE") }) || badgeTexts.contains("LIVE") {
            kind = .live
        } else if badgeStyles.contains(where: { $0.contains("UPCOMING") }) || badgeTexts.contains("UPCOMING") {
            kind = .upcoming
        }

        let duration = badgeTexts.first { $0.contains(":") }
        let progress = image.first("startPercent")?.double
        // Metadata-row badges, e.g. {badgeStyle: BADGE_MEMBERS_ONLY, badgeText: "Members only"}.
        let rowBadges = rows.flatMap { $0["badges"].array.compactMap { $0["badgeViewModel"]["badgeStyle"].string } }

        var video = Video(
            id: id,
            title: title,
            kind: kind,
            channelName: channelName,
            channelId: channelId,
            channelAvatar: url(avatar.first("sources")?[0]["url"].string),
            duration: kind == .video ? duration : nil,
            viewCount: viewCount,
            published: published,
            thumbnails: thumbnails(image["image"]["sources"]),
            watchedFraction: progress.map { $0 / 100 }
        )
        video.isMembersOnly = rowBadges.contains("BADGE_MEMBERS_ONLY")
        video.channelHandle = handle(in: avatar) ?? handle(in: meta["metadata"])
        applyFeedback(r["metadata"].all("listItemViewModel"), to: &video)
        return video
    }

    // MARK: - Shorts

    private static func parseShortsLockup(_ r: JSON) -> Video? {
        guard let id = r["onTap"]["innertubeCommand"]["reelWatchEndpoint"]["videoId"].string
                ?? r.first("reelWatchEndpoint")?["videoId"].string,
              let title = r["overlayMetadata"]["primaryText"]["content"].string else { return nil }
        return Video(
            id: id,
            title: title,
            kind: .short,
            viewCount: r["overlayMetadata"]["secondaryText"]["content"].string,
            thumbnails: thumbnails(r["thumbnailViewModel"]["thumbnailViewModel"]["image"]["sources"].isNull
                ? r["thumbnail"]["sources"]
                : r["thumbnailViewModel"]["thumbnailViewModel"]["image"]["sources"])
        )
    }

    private static func parseReelItem(_ r: JSON) -> Video? {
        guard let id = r["videoId"].string, let title = r["headline"].text else { return nil }
        return Video(
            id: id,
            title: title,
            kind: .short,
            viewCount: r["viewCountText"].text,
            thumbnails: thumbnails(r["thumbnail"]["thumbnails"])
        )
    }

    // MARK: - Feedback

    /// Picks "Not interested" / "Don't recommend channel" from a card's menu items
    /// (`listItemViewModel` on lockups, `menuServiceItemRenderer` on older cards).
    private static func applyFeedback(_ items: [JSON], to video: inout Video) {
        for item in items {
            guard let title = (item["title"].text ?? item["text"].text)?.lowercased(),
                  let token = item.first("feedbackEndpoint")?["feedbackToken"].string else { continue }
            if title.hasPrefix("not interested") { video.notInterestedToken = token }
            else if title.hasPrefix("don't recommend") || title.hasPrefix("don’t recommend") { video.dontRecommendChannelToken = token }
        }
    }

    // MARK: - Helpers

    static func thumbnails(_ list: JSON) -> [Thumbnail] {
        list.array.compactMap { t in
            guard let u = url(t["url"].string) else { return nil }
            return Thumbnail(url: u, width: t["width"].int ?? 0, height: t["height"].int ?? 0)
        }
    }

    static func url(_ string: String?) -> URL? {
        guard var s = string, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }
}
