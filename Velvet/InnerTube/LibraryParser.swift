import Foundation

/// A titled group of videos, e.g. History's "Today" / "Yesterday".
nonisolated struct FeedSection: Identifiable, Sendable {
    var id: String { title ?? "_untitled" }
    var title: String?
    var videos: [Video]
    var shorts: [Video]
}

/// A playlist (or podcast/course) card from the Playlists page.
nonisolated struct PlaylistSummary: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var thumbnail: URL?
    /// e.g. "128 videos"
    var countText: String?
    /// e.g. "Private · Playlist" / "Updated today"
    var subtitle: String?

    /// Browse ID for the playlist's own page.
    var browseId: String { "VL\(id)" }
}

nonisolated enum LibraryParser {
    /// Splits a browse/continuation response into its item sections, keeping their headers.
    static func sections(in json: JSON) -> [FeedSection] {
        let sectionNodes = json.all("itemSectionRenderer")
        guard !sectionNodes.isEmpty else {
            return [section(title: nil, from: json)].filter { !$0.videos.isEmpty || !$0.shorts.isEmpty }
        }
        return sectionNodes.map { node in
            section(title: node["header"]["itemSectionHeaderRenderer"]["title"].text, from: node)
        }
        .filter { !$0.videos.isEmpty || !$0.shorts.isEmpty }
    }

    private static func section(title: String?, from json: JSON) -> FeedSection {
        let all = VideoParser.videos(in: json)
        return FeedSection(title: title, videos: all.filter { $0.kind != .short }, shorts: all.filter { $0.kind == .short })
    }

    static func playlists(in json: JSON) -> [PlaylistSummary] {
        let types: Set<String> = ["LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_PODCAST", "LOCKUP_CONTENT_TYPE_COURSE"]
        var seen = Set<String>()
        return json.all("lockupViewModel").compactMap { l -> PlaylistSummary? in
            guard let id = l["contentId"].string, types.contains(l["contentType"].string ?? ""),
                  seen.insert(id).inserted else { return nil }
            let meta = l["metadata"]["lockupMetadataViewModel"]
            guard let title = meta["title"].text else { return nil }
            let collection = l["contentImage"]["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]
            let thumb = VideoParser.thumbnails(collection["image"]["sources"]).max { $0.width < $1.width }?.url
            let count = collection.all("thumbnailBadgeViewModel").compactMap { $0["text"].string }.first
            let rows = meta["metadata"]["contentMetadataViewModel"]["metadataRows"].array.map { row in
                row["metadataParts"].array.compactMap { $0["text"]["content"].string }.joined(separator: " · ")
            }
            .filter { !$0.lowercased().hasPrefix("view full") } // link text, not metadata
            return PlaylistSummary(id: id, title: title, thumbnail: thumb, countText: count,
                                   subtitle: rows.filter { !$0.isEmpty }.joined(separator: " — "))
        }
    }

    /// Playlist page title, from either header style.
    static func playlistTitle(in json: JSON) -> String? {
        json.first("playlistHeaderRenderer")?["title"].text
            ?? json.first("pageHeaderViewModel")?["title"]["dynamicTextViewModel"]["text"].text
            ?? json["metadata"]["playlistMetadataRenderer"]["title"].string
    }
}
