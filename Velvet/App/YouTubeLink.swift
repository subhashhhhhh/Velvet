import Foundation

/// A YouTube page that Velvet can open: from a link handed to the app (Open With, `open -a`,
/// a `velvet://` link, a drop on the window) or from the clipboard.
nonisolated enum YouTubeLink: Equatable, Sendable {
    case video(id: String, start: Double?)
    case short(id: String)
    case playlist(id: String)
    case channel(id: String)
    /// `/@name`, `/c/name`, `/user/name`: resolved to a channel ID through YouTube.
    case channelURL(URL)

    init?(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if scheme == "velvet" {
            guard let link = Self(velvet: url) else { return nil }
            self = link
            return
        }
        guard scheme == "https" || scheme == "http", var host = url.host()?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? { items.first { $0.name == name }?.value?.nilIfEmpty }
        let start = query("t").flatMap(Self.seconds) ?? query("start").flatMap(Self.seconds)
        let parts = url.pathComponents.filter { $0 != "/" }

        if host == "youtu.be" {
            guard let id = parts.first, Self.isVideoID(id) else { return nil }
            self = .video(id: id, start: start)
            return
        }
        guard host == "youtube.com" || host == "youtube-nocookie.com" else { return nil }

        switch parts.first?.lowercased() {
        case "watch":
            if let id = query("v"), Self.isVideoID(id) {
                self = .video(id: id, start: start)
            } else if let list = query("list") {
                self = .playlist(id: list)
            } else {
                return nil
            }
        case "shorts":
            guard parts.count > 1, Self.isVideoID(parts[1]) else { return nil }
            self = .short(id: parts[1])
        case "live", "embed", "v":
            guard parts.count > 1, Self.isVideoID(parts[1]) else { return nil }
            self = .video(id: parts[1], start: start)
        case "playlist":
            guard let list = query("list") else { return nil }
            self = .playlist(id: list)
        case "channel":
            guard parts.count > 1, parts[1].hasPrefix("UC") else { return nil }
            self = .channel(id: parts[1])
        case "c", "user":
            guard parts.count > 1 else { return nil }
            self = .channelURL(URL(string: "https://www.youtube.com/\(parts[0])/\(parts[1])")!)
        case let first? where first.hasPrefix("@") && first.count > 1:
            guard let resolved = URL(string: "https://www.youtube.com/\(parts[0])") else { return nil }
            self = .channelURL(resolved)
        default:
            return nil
        }
    }

    /// `velvet://open?url=<YouTube link>` (the bookmarklet), `velvet://watch?v=<id>&t=<s>`,
    /// or `velvet://https://www.youtube.com/…` (some tools join the scheme to a link).
    private init?(velvet url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? { items.first { $0.name == name }?.value?.nilIfEmpty }
        switch url.host()?.lowercased() {
        case "open":
            guard let inner = query("url").flatMap(URL.init(string:)), inner.scheme != "velvet",
                  let link = Self(inner) else { return nil }
            self = link
        case "watch":
            guard let id = query("v"), Self.isVideoID(id) else { return nil }
            self = .video(id: id, start: query("t").flatMap(Self.seconds))
        case "https", "http":
            let rest = url.absoluteString.dropFirst("velvet://".count)
            guard let inner = URL(string: "https://" + rest.drop { $0 != "/" }.drop { $0 == "/" }),
                  let link = Self(inner) else { return nil }
            self = link
        default:
            return nil
        }
    }

    /// Finds a YouTube link in copied text (only when the text is the link, give or take spaces).
    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < 2000, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let link = Self(url), url.scheme != "velvet" else { return nil }
        self = link
    }

    var videoID: String? {
        switch self {
        case .video(let id, _), .short(let id): id
        default: nil
        }
    }

    static func isVideoID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `90`, `90s`, `1m30s`, `1h2m3s`.
    static func seconds(_ s: String) -> Double? {
        if let plain = Double(s) { return plain > 0 ? plain : nil }
        var total = 0.0, number = ""
        for c in s.lowercased() {
            if c.isNumber { number.append(c); continue }
            guard let n = Double(number) else { return nil }
            switch c {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            number = ""
        }
        if let n = Double(number) { total += n }
        return total > 0 ? total : nil
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
