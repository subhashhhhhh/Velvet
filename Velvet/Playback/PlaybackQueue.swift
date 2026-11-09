import SwiftUI

/// Videos to play after the current one ("Play Next" / "Add to Queue").
@Observable
final class PlaybackQueue {
    private(set) var items: [Video] = []

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

    func popFirst() -> Video? { items.isEmpty ? nil : items.removeFirst() }
}
