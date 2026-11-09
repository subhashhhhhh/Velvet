import Foundation

/// How often a channel's uploads notify you (YouTube's subscription bell).
nonisolated enum BellSetting: Int, CaseIterable, Identifiable, Sendable {
    // Raw values are YouTube's own codes in the preference request.
    case all = 2, personalized = 1, none = 3

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .personalized: "Personalized"
        case .none: "None"
        }
    }
    var symbol: String {
        switch self {
        case .all: "bell.and.waves.left.and.right.fill"
        case .personalized: "bell"
        case .none: "bell.slash"
        }
    }
}

/// A subscribed channel's bell: the current setting and the request for each choice.
nonisolated struct ChannelBell: Hashable, Sendable {
    var setting: BellSetting?
    var params: [BellSetting: String]

    /// What YouTube sets when you subscribe: Personalized. The pages only carry the bell's
    /// requests for channels you were already subscribed to, so build them.
    static func afterSubscribing(to channelId: String) -> ChannelBell {
        ChannelBell(setting: .personalized,
                    params: Dictionary(uniqueKeysWithValues: BellSetting.allCases.map { ($0, NotificationParser.bellParams(channelId: channelId, setting: $0)) }))
    }
}

/// One item in YouTube's notification inbox.
nonisolated struct InboxNotification: Identifiable, Hashable, Sendable {
    let id: String
    var message: String
    var sent: String?
    var isRead: Bool
    var channelAvatar: URL?
    var thumbnail: URL?
    /// The video it's about (nil for a few kinds, e.g. community posts).
    var videoId: String?
    var isShort: Bool
    /// About your comments (a reply, a heart) rather than a new video.
    var isComment: Bool
    /// Marks it read on YouTube when opened.
    var readToken: String?

    var video: Video? {
        guard let videoId else { return nil }
        return Video(id: videoId, title: uploadTitle ?? message, kind: isShort ? .short : .video)
    }

    /// "Supabase uploaded: What Tech Stack…" → ("Supabase", "What Tech Stack…").
    var uploader: String? { split?.0 }
    var uploadTitle: String? { split?.1 }
    private var split: (String, String)? {
        guard let r = message.range(of: " uploaded: ") else { return nil }
        return (String(message[..<r.lowerBound]), String(message[r.upperBound...]))
    }
}

nonisolated struct InboxPage: Sendable {
    var items: [InboxNotification]
    var continuation: String?
}

nonisolated enum NotificationParser {
    /// The bell choices in a channel's subscribe button, from either layout (the watch page's
    /// toggle-button renderer or the channel page's view models). Nil when not subscribed.
    static func bell(in json: JSON) -> ChannelBell? {
        var bell = ChannelBell(setting: nil, params: [:])
        collectBellItems(json, into: &bell)
        return bell.params.isEmpty ? nil : bell
    }

    /// Finds menu items that carry a bell request and reads their title and selection.
    private static func collectBellItems(_ json: JSON, into bell: inout ChannelBell) {
        switch json {
        case .object(let o):
            let title = (o["text"] ?? o["title"])?.text
            if let title, o["modifyChannelNotificationPreferenceEndpoint"] == nil,
               let params = json.first("modifyChannelNotificationPreferenceEndpoint")?["params"].string,
               let setting = BellSetting.allCases.first(where: { $0.label.caseInsensitiveCompare(title) == .orderedSame }) {
                bell.params[setting] = params
                if o["isSelected"]?.bool == true { bell.setting = setting }
                return
            }
            for v in o.values { collectBellItems(v, into: &bell) }
        case .array(let a):
            for v in a { collectBellItems(v, into: &bell) }
        default:
            break
        }
    }

    /// The bell request YouTube's pages send: protobuf
    /// `{1: channelId, 2: {1: setting}, 3: 0, 4: 4, 10: {1: {1: 1}, 2: {}, 3: 0}}`.
    static func bellParams(channelId: String, setting: BellSetting) -> String {
        let id = Array(channelId.utf8)
        var bytes: [UInt8] = [0x0A, UInt8(id.count)] + id
        bytes += [0x12, 0x02, 0x08, UInt8(setting.rawValue), 0x18, 0x00, 0x20, 0x04,
                  0x52, 0x08, 0x0A, 0x02, 0x08, 0x01, 0x12, 0x00, 0x18, 0x00]
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "%3D")
    }

    static func unseenCount(from json: JSON) -> Int? {
        json.first("unseenCount")?.int
    }

    static func inbox(from json: JSON) -> InboxPage {
        let items = json.all("notificationRenderer").compactMap { n -> InboxNotification? in
            guard let id = n["notificationId"].string, let message = n["shortMessage"].text else { return nil }
            let nav = n["navigationEndpoint"]
            let reel = nav.first("reelWatchEndpoint")?["videoId"].string
            // Replies and hearts open the video's comments with the reply linked.
            let comment = nav.first("getCommentsFromInboxCommand")
            return InboxNotification(
                id: id,
                message: message,
                sent: n["sentTimeText"].text,
                isRead: n["read"].bool ?? false,
                channelAvatar: VideoParser.thumbnails(n["thumbnail"]["thumbnails"]).max { $0.width < $1.width }?.url,
                thumbnail: VideoParser.thumbnails(n["videoThumbnail"]["thumbnails"]).max { $0.width < $1.width }?.url,
                videoId: reel ?? nav.first("watchEndpoint")?["videoId"].string ?? comment?["videoId"].string,
                isShort: reel != nil,
                isComment: comment != nil,
                readToken: n["recordClickEndpoint"].first("serializedInteractionsRequest")?.string
            )
        }
        let token = json.all("continuationItemRenderer").compactMap { $0.first("ctoken")?.string }.last
        return InboxPage(items: items, continuation: token)
    }
}
