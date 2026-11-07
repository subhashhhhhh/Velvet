import Foundation

/// Exact resume positions for videos watched in Velvet, kept on this Mac.
///
/// YouTube also reports progress, but only as a rounded percentage that updates lazily, so
/// this local record wins when present. It's also what a local (signed-out) profile uses.
@Observable
final class WatchProgressStore {
    nonisolated struct Entry: Codable, Sendable {
        var position: Double
        var duration: Double
        var updatedAt: Date
    }

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let url: URL
    private static let limit = 2000

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "com.subhash.Velvet", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "progress.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    func record(_ videoId: String, position: Double, duration: Double) {
        guard duration > 0, position.isFinite else { return }
        entries[videoId] = Entry(position: position, duration: duration, updatedAt: .now)
        if entries.count > Self.limit {
            // Drop the oldest ~10% in one go rather than on every write.
            let oldest = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(Self.limit / 10)
            for (id, _) in oldest { entries[id] = nil }
        }
        scheduleSave()
    }

    func fraction(for videoId: String) -> Double? {
        entries[videoId].map { min(1, $0.position / $0.duration) }
    }

    /// Where to resume `video`, or nil to start from the beginning.
    func resumePosition(for video: Video) -> Double? {
        if let e = entries[video.id] {
            return Self.resumable(e.position, of: e.duration)
        }
        // Fall back to YouTube's percentage (e.g. watched on another device).
        if let f = video.watchedFraction, let d = video.durationSeconds {
            return Self.resumable(f * d, of: d)
        }
        return nil
    }

    /// Skip trivially-started or essentially-finished videos; back up a few seconds for context.
    private static func resumable(_ position: Double, of duration: Double) -> Double? {
        guard position > 10, position < duration - 15, position / duration < 0.95 else { return nil }
        return max(0, position - 3)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [url] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Writes pending changes immediately (app quitting).
    func saveNow() {
        saveTask?.cancel()
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}

extension Video {
    /// "1:02:03" / "12:04" → seconds.
    nonisolated var durationSeconds: Double? {
        guard let duration else { return nil }
        let parts = duration.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
