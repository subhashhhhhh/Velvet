import Foundation

nonisolated struct Account: Hashable, Sendable {
    var name: String
    var handle: String?
    var photo: URL?

    /// Parses `account/account_menu` (activeAccountHeaderRenderer).
    init?(accountMenu json: JSON) {
        guard let header = json.first("activeAccountHeaderRenderer"),
              let name = header["accountName"].text else { return nil }
        self.name = name
        handle = header["channelHandle"].text ?? header["email"].text
        let thumbs = VideoParser.thumbnails(header["accountPhoto"]["thumbnails"])
        photo = thumbs.max { $0.width < $1.width }?.url
    }
}
