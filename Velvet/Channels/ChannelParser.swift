import Foundation

nonisolated struct ChannelTab: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case videos, shorts, live, playlists }
    var id: String { kind.rawValue }
    let kind: Kind
    let title: String
    let params: String
}

nonisolated struct ChannelHeader: Sendable {
    let id: String
    var name: String
    var handle: String?
    var avatar: URL?
    var banner: URL?
    var subscribers: String?
    var videoCount: String?
    var description: String?
    var isSubscribed: Bool
    /// The channel's notification bell (subscribed channels only).
    var bell: ChannelBell?
    var tabs: [ChannelTab]
}

/// A sort option on a channel tab ("Latest", "Popular", "Oldest").
nonisolated struct SortChip: Identifiable, Hashable, Sendable {
    var id: String { title }
    let title: String
    let token: String
    let selected: Bool
}

nonisolated enum ChannelParser {
    static func header(from json: JSON, channelId: String) -> ChannelHeader? {
        guard let h = json.first("pageHeaderViewModel") else { return nil }
        let name = h["title"]["dynamicTextViewModel"]["text"]["content"].string
            ?? json["metadata"]["channelMetadataRenderer"]["title"].string
        guard let name else { return nil }

        let rows = h["metadata"]["contentMetadataViewModel"]["metadataRows"].array
        let parts = rows.flatMap { $0["metadataParts"].array.compactMap { $0["text"]["content"].string } }
        let handle = parts.first { $0.hasPrefix("@") }
        let subscribers = parts.first { $0.localizedCaseInsensitiveContains("subscriber") }
        let videoCount = parts.first { $0.localizedCaseInsensitiveContains("video") }

        // The subscribe button carries both states; the real one is an entity in frameworkUpdates.
        var subscribed = false
        if let sb = h.first("subscribeButtonViewModel"), let key = sb["stateEntityStoreKey"].string {
            for m in json["frameworkUpdates"]["entityBatchUpdate"]["mutations"].array where m["entityKey"].string == key {
                subscribed = m["payload"]["subscriptionStateEntity"]["subscribed"].bool ?? false
            }
        }

        let kinds: [String: ChannelTab.Kind] = ["videos": .videos, "shorts": .shorts, "live": .live, "playlists": .playlists]
        let tabs = json.all("tabRenderer").compactMap { tab -> ChannelTab? in
            guard let title = tab["title"].string, let params = tab["endpoint"]["browseEndpoint"]["params"].string,
                  let kind = kinds[title.lowercased()] else { return nil }
            return ChannelTab(kind: kind, title: title, params: params)
        }

        func best(_ sources: JSON) -> URL? { VideoParser.thumbnails(sources).max { $0.width < $1.width }?.url }
        return ChannelHeader(
            id: channelId,
            name: name,
            handle: handle,
            avatar: best(h["image"]["decoratedAvatarViewModel"]["avatar"]["avatarViewModel"]["image"]["sources"]),
            banner: best(h["banner"]["imageBannerViewModel"]["image"]["sources"]),
            subscribers: subscribers,
            videoCount: videoCount,
            description: h["description"]["descriptionPreviewViewModel"]["description"]["content"].string,
            isSubscribed: subscribed,
            bell: subscribed ? bell(in: h, json: json) : nil,
            tabs: tabs
        )
    }

    /// The bell's choices; the current one from the menu's selection, else from the
    /// notification-state entity the subscribe button links to.
    private static func bell(in header: JSON, json: JSON) -> ChannelBell? {
        guard var bell = NotificationParser.bell(in: header) else { return nil }
        if bell.setting == nil, let key = header.first("subsNotificationStateKey")?.string {
            for m in json["frameworkUpdates"]["entityBatchUpdate"]["mutations"].array where m["entityKey"].string == key {
                switch m["payload"]["subscriptionNotificationStateEntity"]["state"].string {
                case "SUBSCRIPTION_NOTIFICATION_STATE_ALL": bell.setting = .all
                case "SUBSCRIPTION_NOTIFICATION_STATE_OCCASIONAL": bell.setting = .personalized
                case "SUBSCRIPTION_NOTIFICATION_STATE_OFF": bell.setting = .none
                default: break
                }
            }
        }
        return bell
    }

    static func sortChips(in json: JSON) -> [SortChip] {
        json.all("chipViewModel").compactMap { c in
            guard let title = c["text"].string, let token = c.first("token")?.string else { return nil }
            return SortChip(title: title, token: token, selected: c["selected"].bool ?? false)
        }
    }
}
