import Foundation
import OSLog

/// Hides videos from channels on AiSList (aisloplist.com), a community list of YouTube
/// channels that post AI-generated videos: a blocklist (high confidence, ~50k channels) and a
/// warnlist (likely). The lists are @handles, downloaded from GitHub at most once a day and
/// only while the filter is on. They're kept as 64-bit fingerprints, about 1 MB, not as text.
@Observable
final class AIChannelFilter {
    private(set) var blocked: Set<UInt64> = []
    private(set) var likely: Set<UInt64> = []
    private(set) var lastUpdated: Date?

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var loading = false
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "AIFilter")

    nonisolated private static let lists = [
        ("blocklist", URL(string: "https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_blocklist.txt")!),
        ("warnlist", URL(string: "https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_warnlist.txt")!),
    ]
    nonisolated private static let refreshAfter: TimeInterval = 24 * 3600

    init(preferences: Preferences) { prefs = preferences }

    var isOn: Bool { prefs.hideAIChannels }

    func hides(_ video: Video) -> Bool {
        guard prefs.hideAIChannels, let handle = video.channelHandle else { return false }
        let key = Self.fingerprint(handle)
        return blocked.contains(key) || (prefs.hideAILikely && likely.contains(key))
    }

    /// Loads the cached lists, and downloads fresh ones when they're a day old.
    func refreshIfNeeded() async {
        guard prefs.hideAIChannels, !loading else { return }
        loading = true
        defer { loading = false }
        let result = await Self.load()
        blocked = result.blocked
        likely = result.likely
        lastUpdated = result.updated
        log.info("AiSList: \(result.blocked.count) blocked, \(result.likely.count) likely")
        MemoryRelief.soon()
    }

    /// Drops the lists from memory when the filter is turned off.
    func unload() {
        blocked = []
        likely = []
    }

    private struct Loaded: Sendable {
        var blocked: Set<UInt64>
        var likely: Set<UInt64>
        var updated: Date?
    }

    @concurrent
    private static func load() async -> Loaded {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Velvet/AiSList", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sets: [String: Set<UInt64>] = [:]
        var updated: Date?
        for (name, url) in lists {
            let file = dir.appending(path: "\(name).txt")
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date().timeIntervalSince($0) }
            if age == nil || age! > refreshAfter,
               let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 {
                try? data.write(to: file, options: .atomic)
            }
            if let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                updated = max(updated ?? date, date)
            }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var set = Set<UInt64>()
            // "! comment" lines and UC channel IDs are skipped; only @handles are listed by name.
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("@") {
                set.insert(fingerprint(line.trimmingCharacters(in: .whitespaces).lowercased()))
            }
            sets[name] = set
        }
        return Loaded(blocked: sets["blocklist"] ?? [], likely: sets["warnlist"] ?? [], updated: updated)
    }

    /// FNV-1a: stable across launches, unlike Hasher.
    nonisolated static func fingerprint(_ handle: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in handle.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
}
