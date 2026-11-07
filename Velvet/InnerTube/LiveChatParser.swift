import Foundation

nonisolated struct LiveChatMessage: Identifiable, Hashable, Sendable {
    enum Role: Sendable { case viewer, member, moderator, owner }

    let id: String
    var author: String
    var authorChannelId: String?
    var avatar: URL?
    /// Message text with standard emoji inlined and custom emoji as ":shortcut:".
    var text: String
    var role: Role
    var isVerified: Bool
    /// Super Chat amount and highlight colour, when paid.
    var paidAmount: String?
    var paidColor: UInt32?
}

nonisolated struct LiveChatPage: Sendable {
    var added: [LiveChatMessage]
    var removedIds: [String]
    var continuation: String?
    /// How long YouTube asks us to wait before the next request.
    var pollAfter: Duration
}

nonisolated enum LiveChatParser {
    static func page(from json: JSON) -> LiveChatPage {
        let chat = json["continuationContents"]["liveChatContinuation"]
        var added: [LiveChatMessage] = []
        var removed: [String] = []
        for action in chat["actions"].array {
            if let item = action["addChatItemAction"]["item"].object {
                if let r = item["liveChatTextMessageRenderer"], let m = message(r) { added.append(m) }
                if let r = item["liveChatPaidMessageRenderer"], var m = message(r) {
                    m.paidAmount = r["purchaseAmountText"].text
                    m.paidColor = r["bodyBackgroundColor"].double.map { UInt32(truncatingIfNeeded: Int64($0)) }
                    added.append(m)
                }
            }
            if let id = action["removeChatItemAction"]["targetItemId"].string { removed.append(id) }
        }

        // Exactly one of these continuation kinds is present; each carries the next token and a wait.
        var token: String?
        var wait = Duration.seconds(5)
        for c in chat["continuations"].array {
            for key in ["invalidationContinuationData", "timedContinuationData", "reloadContinuationData"] {
                let data = c[key]
                if let t = data["continuation"].string {
                    token = t
                    if let ms = data["timeoutMs"].double { wait = .milliseconds(Int(ms)) }
                }
            }
        }
        // Keep polling within sane bounds regardless of what the server suggests.
        wait = min(max(wait, .seconds(1)), .seconds(10))
        return LiveChatPage(added: added, removedIds: removed, continuation: token, pollAfter: wait)
    }

    private static func message(_ r: JSON) -> LiveChatMessage? {
        guard let id = r["id"].string else { return nil }
        var text = ""
        for run in r["message"]["runs"].array {
            if let t = run["text"].string {
                text += t
            } else if !run["emoji"].isNull {
                let e = run["emoji"]
                // Standard emoji use the character itself as the ID; custom ones get their shortcut.
                if e["isCustomEmoji"].bool == true {
                    text += e["shortcuts"][0].string ?? e["searchTerms"][0].string.map { ":\($0):" } ?? ""
                } else {
                    text += e["emojiId"].string ?? e["shortcuts"][0].string ?? ""
                }
            }
        }

        var role = LiveChatMessage.Role.viewer
        var verified = false
        for badge in r["authorBadges"].array {
            let b = badge["liveChatAuthorBadgeRenderer"]
            switch b["icon"]["iconType"].string {
            case "OWNER": role = .owner
            case "MODERATOR": if role != .owner { role = .moderator }
            case "VERIFIED": verified = true
            default:
                if !b["customThumbnail"].isNull, role == .viewer { role = .member } // membership badges are images
            }
        }

        return LiveChatMessage(
            id: id,
            author: r["authorName"].text ?? "",
            authorChannelId: r["authorExternalChannelId"].string,
            avatar: VideoParser.thumbnails(r["authorPhoto"]["thumbnails"]).max { $0.width < $1.width }?.url,
            text: text,
            role: role,
            isVerified: verified
        )
    }

    /// The "Top chat" token from a live video's watch page (`next`), if it has live chat.
    static func initialToken(from next: JSON) -> String? {
        let renderer = next["contents"]["twoColumnWatchNextResults"]["conversationBar"]["liveChatRenderer"]
        guard renderer["isReplay"].bool != true else { return nil } // replays need a different endpoint
        return renderer["continuations"][0]["reloadContinuationData"]["continuation"].string
    }
}
