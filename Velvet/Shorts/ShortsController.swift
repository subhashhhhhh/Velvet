import SwiftUI

/// Drives the Shorts player: one PlayerSession for the current Short, prefetching the next.
@Observable
final class ShortsController {
    enum Panel: Equatable { case none, description, comments }

    let sequence: ShortsSequence
    private(set) var session: PlayerSession?
    var panel: Panel = .none
    /// The last move: +1 next (slides up), −1 previous (slides down).
    private(set) var direction = 1
    /// During a slide, the card keeps the outgoing Short's shape (width ÷ height), so both
    /// slide through the same frame; it reshapes to the new video after.
    private(set) var slideAspect: CGFloat?
    @ObservationIgnored private var slideEnd: Task<Void, Never>?

    static let slide: Animation = {
        #if DEBUG
        // `-VelvetSlowShorts YES`: a 3 s slide, to inspect it frame by frame.
        if UserDefaults.standard.bool(forKey: "VelvetSlowShorts") { return .smooth(duration: 3) }
        #endif
        return .smooth(duration: 0.35)
    }()

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
        direction = delta > 0 ? 1 : -1
        if slideAspect == nil, let size = session?.player.videoSize, size.width > 0, size.height > 0 {
            slideAspect = size.width / size.height
        }
        withAnimation(Self.slide) { playCurrent(animated: true) }
        slideEnd?.cancel()
        slideEnd = Task {
            try? await Task.sleep(for: .milliseconds(UserDefaults.standard.bool(forKey: "VelvetSlowShorts") ? 3200 : 450))
            if !Task.isCancelled { slideAspect = nil }
        }
    }

    func pause() { session?.player.pause() }

    func close() {
        closed = true
        session?.close()
        session = nil
    }

    private func playCurrent(animated: Bool = false) {
        guard !closed, let app, let video = sequence.current else { return }
        if animated, let old = session {
            // It slides out with its last frame showing: pause now, close after the slide.
            old.player.pause()
            Task {
                try? await Task.sleep(for: .milliseconds(UserDefaults.standard.bool(forKey: "VelvetSlowShorts") ? 3200 : 450))
                old.close()
            }
        } else {
            session?.close()
        }
        let s = app.makeSession(for: video)
        session = s
        s.start()
        if let next = sequence.next { app.prefetch(next) }
    }
}
