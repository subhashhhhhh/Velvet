import AppKit
import ObjectiveC
import OSLog

/// System Picture in Picture for mpv's Metal layer, via macOS's private `PIP.framework`
/// (the same `PIPViewController` IINA uses). The public AVKit PiP only accepts AVPlayer /
/// sample-buffer layers, but PIPViewController can host any view, so mpv keeps rendering
/// into the same layer with no stream switch.
///
/// Everything is resolved at runtime: if the framework or class ever disappears, `isAvailable`
/// is false and the PiP UI simply doesn't show.
final class PictureInPicture: NSObject {
    static let isAvailable: Bool = {
        guard dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP", RTLD_NOW) != nil else { return false }
        return NSClassFromString("PIPViewController") != nil
    }()

    private(set) var isActive = false
    /// True when PiP started because the window was hidden (so showing it again should end PiP).
    private(set) var startedAutomatically = false

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    /// PiP closed (via its own buttons or `exit()`); the caller moves the video back inline.
    var onClosed: (() -> Void)?

    private var pip: NSViewController?
    private var content: NSViewController?
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "PiP")

    /// Shows `view` in a system PiP window. `returnRect` (window coordinates) is where the
    /// video animates back to when PiP closes.
    func enter(view: NSView, aspect: CGSize, playing: Bool, returnTo window: NSWindow?, rect: NSRect?, automatic: Bool) {
        guard Self.isAvailable, !isActive,
              let cls = NSClassFromString("PIPViewController") as? NSViewController.Type else { return }
        let pip = cls.init()
        let content = NSViewController()
        content.view = view

        pip.setValue(self, forKey: "delegate")
        pip.setValue(NSValue(size: aspect.width > 0 && aspect.height > 0 ? aspect : CGSize(width: 16, height: 9)), forKey: "aspectRatio")
        pip.setValue(true, forKey: "userCanResize")
        pip.setValue(playing, forKey: "playing")
        if let window, let rect {
            pip.setValue(window, forKey: "replacementWindow")
            pip.setValue(NSValue(rect: rect), forKey: "replacementRect")
        }

        self.pip = pip
        self.content = content
        isActive = true
        isPresenting = true
        exitRequested = false
        startedAutomatically = automatic
        let start = ContinuousClock.now
        let completion: @convention(block) () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPresenting = false
                self.log.info("PiP presented in \(ContinuousClock.now - start, privacy: .public)")
                // Came back before PiP finished appearing: finish the exit now.
                if self.exitRequested { self.exit() }
            }
        }
        Self.call(pip, "presentViewControllerAsPictureInPicture:completionHandler:", content, completion)
        log.info("Entered PiP (\(automatic ? "automatic" : "manual", privacy: .public))")
    }

    private var isPresenting = false
    private var exitRequested = false

    /// objc_msgSend for `(id, block)` selectors, which `perform(_:with:)` can't express.
    private static func call(_ target: NSObject, _ selector: String, _ object: AnyObject, _ block: @escaping @convention(block) () -> Void) {
        let sel = NSSelectorFromString(selector)
        guard let method = class_getInstanceMethod(type(of: target), sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        let imp = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        imp(target, sel, object, block as AnyObject)
    }

    func setPlaying(_ playing: Bool) {
        pip?.setValue(playing, forKey: "playing")
    }

    func setAspect(_ aspect: CGSize) {
        guard aspect.width > 0, aspect.height > 0 else { return }
        pip?.setValue(NSValue(size: aspect), forKey: "aspectRatio")
    }

    /// Ends PiP, animating back to the replacement rect.
    func exit(returnTo window: NSWindow? = nil, rect: NSRect? = nil) {
        guard isActive, let pip, let content else { return }
        // Dismissing mid-presentation is ignored by PIP.framework; do it once it's shown.
        if isPresenting { exitRequested = true; return }
        if let window, let rect {
            pip.setValue(window, forKey: "replacementWindow")
            pip.setValue(NSValue(rect: rect), forKey: "replacementRect")
        }
        pip.dismiss(content)
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
        startedAutomatically = false
        pip = nil
        content = nil
        log.info("Left PiP")
        onClosed?()
    }

    // MARK: - PIPViewControllerDelegate (informal; selector names as used by IINA)

    @objc func pipShouldClose(_ pip: NSViewController) -> Bool { true }
    @objc func pipWillClose(_ pip: NSViewController) {}
    @objc func pipDidClose(_ pip: NSViewController) { finish() }
    @objc func pipActionPlay(_ pip: NSViewController) { onPlay?() }
    @objc func pipActionPause(_ pip: NSViewController) { onPause?() }
    @objc func pipActionStop(_ pip: NSViewController) { onPause?() }
}
