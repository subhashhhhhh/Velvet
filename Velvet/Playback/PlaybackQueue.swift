import SwiftUI

/// Videos to play after the current one ("Play Next" / "Add to Queue").
@Observable
final class PlaybackQueue {
    private(set) var items: [Video] = [] {
        didSet { if items.isEmpty { source = nil } }
    }
    /// The playlist the queue was filled from, while it's playing through it.
    private(set) var source: String?

    var isEmpty: Bool { items.isEmpty }

    /// Adds to the end (no duplicates).
    func add(_ video: Video) {
        guard !items.contains(where: { $0.id == video.id }) else { return }
        items.append(video)
    }

    /// Puts the video first, moving it if it's already queued.
    func playNext(_ video: Video) {
        items.removeAll { $0.id == video.id }
        items.insert(video, at: 0)
    }

    func remove(_ id: String) { items.removeAll { $0.id == id } }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func clear() { items.removeAll() }

    /// Playing a playlist: its remaining videos replace the queue, like an album in Music.
    func replace(with videos: [Video], source: String) {
        var seen = Set<String>()
        items = videos.filter { seen.insert($0.id).inserted }
        self.source = items.isEmpty ? nil : source
    }

    func popFirst() -> Video? { items.isEmpty ? nil : items.removeFirst() }
}
