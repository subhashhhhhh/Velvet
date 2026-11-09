import SwiftUI

/// Videos to play after the current one ("Play Next" / "Add to Queue", a playlist played
/// through). It also remembers what it has already played, so the watch page can show the
/// whole list with the current video highlighted, like YouTube's playlist panel.
@Observable
final class PlaybackQueue {
    /// Still to play, in order.
    private(set) var items: [Video] = []
    /// Started from this queue, oldest first. The last one is the video playing now when it
    /// came from the queue.
    private(set) var played: [Video] = []
    /// The playlist the queue was filled from (nil: videos added by hand).
    private(set) var source: String?
    /// Starts over from the top after the last video.
    var loops = false

    /// Nothing to play next (a looping queue always has its first video).
    var isEmpty: Bool { items.isEmpty && !(loops && played.count > 1) }

    /// The whole list is showing: something queued, or a played-through list still on screen.
    var hasContent: Bool { !items.isEmpty || !played.isEmpty }

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

    func clear() {
        items.removeAll()
        played.removeAll()
        source = nil
        loops = false
    }

    /// Playing a playlist from `index`: everything before and including it counts as played,
    /// the rest replaces the queue (like playing an album in Music).
    func start(_ videos: [Video], at index: Int, source: String) {
        var seen = Set<String>()
        let unique = videos.filter { seen.insert($0.id).inserted }
        let i = min(max(0, index), unique.count - 1)
        guard i >= 0 else { return }
        played = Array(unique[...i])
        items = Array(unique[(i + 1)...])
        self.source = source
    }

    /// The next video, which now counts as played. With looping on, an exhausted queue starts
    /// over from the first video.
    func popFirst() -> Video? {
        if items.isEmpty, loops, played.count > 1 {
            items = played
            played = []
        }
        guard !items.isEmpty else { return nil }
        let next = items.removeFirst()
        played.append(next)
        return next
    }

    /// Jumps to a video anywhere in the list (played or upcoming), keeping the order: what's
    /// before it becomes played, what's after it upcoming.
    func jump(to id: String) -> Video? {
        let all = played + items
        guard let i = all.firstIndex(where: { $0.id == id }) else { return nil }
        played = Array(all[...i])
        items = Array(all[(i + 1)...])
        return all[i]
    }

    /// Shuffles what's still to play.
    func shuffle() { items.shuffle() }
}
