import Foundation

/// Drives the Shorts player: one PlayerSession for the current Short, prefetching the next.
@Observable
final class ShortsController {
    enum Panel: Equatable { case none, description, comments }

    let sequence: ShortsSequence
    private(set) var session: PlayerSession?
    var panel: Panel = .none

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var started = false
    /// Once closed, an in-flight start must never begin playback (it would play unseen).
    @ObservationIgnored private var closed = false

    init(sequence: ShortsSequence, app: AppModel) {
        self.sequence = sequence
        self.app = app
    }

    func start() async {
        guard !started else {
            session?.player.play()
            return
        }
        started = true
        await sequence.start()
        playCurrent()
    }

    func go(_ delta: Int) {
        let before = sequence.index
        sequence.move(delta)
        guard sequence.index != before else { return }
        playCurrent()
    }

    func pause() { session?.player.pause() }

    func close() {
        closed = true
        session?.close()
        session = nil
    }

    private func playCurrent() {
        guard !closed, let app, let video = sequence.current else { return }
        session?.close()
        let s = app.makeSession(for: video)
        session = s
        s.start()
        if let next = sequence.next { app.prefetch(next) }
    }
}
