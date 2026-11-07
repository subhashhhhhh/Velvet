import SwiftUI
import ImageIO

/// Plays an animated image (GIF / animated WebP) with ImageIO, one decoded frame at a time.
/// Animation runs only while the view is in a window, so off-screen comments cost nothing.
struct AnimatedImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AnimatedImageView { AnimatedImageView(url: url) }
    func updateNSView(_ view: AnimatedImageView, context: Context) { view.url = url }
    static func dismantleNSView(_ view: AnimatedImageView, coordinator: ()) { view.stop() }
}

final class AnimatedImageView: NSView {
    var url: URL { didSet { if url != oldValue { stop(); data = nil; startIfVisible() } } }
    private var data: Data?
    private var loadTask: Task<Void, Never>?
    /// Bumped on every start/stop; a running animation stops itself once it's stale.
    private var generation = 0

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stop() : startIfVisible()
    }

    func stop() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
    }

    private func startIfVisible() {
        guard window != nil else { return }
        if let data { animate(data); return }
        let url = url
        loadTask = Task { [weak self] in
            guard let bytes = await ImagePipeline.shared.data(for: url), !Task.isCancelled, let self else { return }
            self.data = bytes
            self.animate(bytes)
        }
    }

    private func animate(_ data: Data) {
        generation += 1
        let mine = generation
        // Respect Reduce Motion: show the first frame only.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let first = CGImageSourceCreateImageAtIndex(src, 0, nil) { layer?.contents = first }
            return
        }
        CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, image, stop in
            guard let self, self.generation == mine else { stop.pointee = true; return }
            self.layer?.contents = image
            self.layer?.backgroundColor = nil
        }
    }
}
