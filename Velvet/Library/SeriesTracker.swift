import Foundation
import OSLog

/// A video that's an episode of a series: "Learn Swift - Lesson 4 - Arrays",
/// "100 Hours in Minecraft: Episode 3 - Base Building", "My Hardcore World #12".
nonisolated struct SeriesEpisode: Hashable, Sendable {
    /// Identifies the series: the channel, the marker word and the title before the number.
    let key: String
    /// The series as titled, e.g. "Learn Swift for Beginners".
    let name: String
    /// "Lesson", "Episode", "#"…
    let marker: String
    let number: Int

    /// Episode markers. The title before one names the series; a bare "#12" counts only at the
    /// end of a title ("The WORST #1 Ever" isn't an episode).
    private static let patterns: [(NSRegularExpression, String?)] = [
        (try! NSRegularExpression(pattern: #"\b(part|pt\.?|episode|ep\.?|chapter|ch\.?|lesson|day|week|session|round|stage|level|vol\.?|volume)\s*#?\s*(\d{1,4})\b"#, options: .caseInsensitive), nil),
        (try! NSRegularExpression(pattern: #"\bs\d{1,2}\s*(e)(\d{1,3})\b"#, options: .caseInsensitive), nil),
        (try! NSRegularExpression(pattern: #"[(\[]?(#)(\d{1,4})[)\]]?\s*$"#), nil),
    ]

    init?(title: String, channel: String) {
        let ns = title as NSString
        for (regex, _) in Self.patterns {
            guard let m = regex.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)),
                  let number = Int(ns.substring(with: m.range(at: 2))), number > 0 else { continue }
            let marker = ns.substring(with: m.range(at: 1))
            var name = ns.substring(to: m.range.location)
            // Prefix too short to name anything ("Episode 3 - The Cave"): name it by what follows.
            if Self.normalized(name).count < 3 { name = ns.substring(from: NSMaxRange(m.range)) }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|:([.,!?…").union(.whitespaces))
            let normalizedName = Self.normalized(name)
            guard normalizedName.count >= 3 else { return nil }
            let markerKey = marker.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            key = "\(channel)|\(markerKey)|\(normalizedName)"
            self.name = name
            self.marker = marker.count > 1 ? marker.prefix(1).uppercased() + marker.dropFirst().lowercased() : marker
            self.number = number
            return
        }
        return nil
    }

    /// "Lesson 5", "Episode 4", "#13".
    func label(for n: Int) -> String { marker == "#" ? "#\(n)" : marker == "e" || marker == "E" ? "E\(n)" : "\(marker) \(n)" }

    private static func normalized(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Series you're watching, kept on this Mac: the last episode of each and, once looked up,
/// the next one. Feeds the "Next in this series" card and History's Continue Watching row.
@Observable
final class SeriesTracker {
    nonisolated struct Entry: Codable, Hashable, Sendable, Identifiable {
        var id: String { key }
        let key: String
        var name: String
        var channelId: String?
        var channelName: String?
        var number: Int
        var label: String
        var video: Stored
        var next: Stored?
        var updatedAt: Date
    }

    nonisolated struct Stored: Codable, Hashable, Sendable {
        let id: String
        let title: String
        var thumbnail: URL?

        init(_ v: Video) {
            id = v.id
            title = v.title
            thumbnail = v.thumbnail(minWidth: 320)
        }

        var video: Video { Video(id: id, title: title) }
    }

    private(set) var entries: [String: Entry] = [:]

    @ObservationIgnored private let client: InnerTubeClient
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "Series")
    private static let limit = 100

    init(client: InnerTubeClient) {
        self.client = client
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Velvet", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "series.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    /// Series in progress, most recent first.
    var inProgress: [Entry] { entries.values.sorted { $0.updatedAt > $1.updatedAt } }

    /// The entry for this video's series if it's the episode being tracked.
    func entry(for videoId: String) -> Entry? { entries.values.first { $0.video.id == videoId } }

    /// Watching an episode: remember it and look up the one after (a channel search).
    func watching(_ video: Video, title: String, channelId: String?, channelName: String?) async -> Entry? {
        guard let channel = channelId ?? channelName,
              let episode = SeriesEpisode(title: title, channel: channel) else { return nil }
        var current = video
        current.title = title
        // Re-watching an older episode doesn't move the series back… unless it's the one tracked.
        if let existing = entries[episode.key], existing.number > episode.number { return nil }
        var entry = entries[episode.key] ?? Entry(key: episode.key, name: episode.name, channelId: channelId,
                                                  channelName: channelName, number: episode.number,
                                                  label: episode.label(for: episode.number), video: Stored(current),
                                                  next: nil, updatedAt: .now)
        if entry.video.id != video.id { entry.next = nil }
        entry.number = episode.number
        entry.label = episode.label(for: episode.number)
        entry.video = Stored(current)
        entry.updatedAt = .now
        entries[episode.key] = entry
        save()
        if entry.next == nil, let channelId, let next = await findNext(after: episode, channelId: channelId) {
            entries[episode.key]?.next = Stored(next)
            save()
        }
        log.info("Series \(episode.name, privacy: .public) \(episode.label(for: episode.number), privacy: .public): next \(self.entries[episode.key]?.next?.title ?? "not found", privacy: .public)")
        return entries[episode.key]
    }

    func remove(_ key: String) {
        entries[key] = nil
        save()
    }

    /// Searches the channel for "<series> <marker> <n+1>" and takes the result that's the same
    /// series with the next number.
    private func findNext(after episode: SeriesEpisode, channelId: String) async -> Video? {
        let query = "\(episode.name) \(episode.label(for: episode.number + 1))"
        guard let json = try? await client.browse(channelId, params: ChannelTabContent.searchParams, query: query) else { return nil }
        let videos = VideoParser.videos(in: json)
        MemoryRelief.soon()
        return videos.first { v in
            guard let e = SeriesEpisode(title: v.title, channel: episode.key.components(separatedBy: "|")[0]) else { return false }
            return e.key == episode.key && e.number == episode.number + 1
        }
    }

    private func save() {
        if entries.count > Self.limit {
            for old in entries.values.sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(entries.count - Self.limit) {
                entries[old.key] = nil
            }
        }
        let snapshot = entries
        let url = url
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}
