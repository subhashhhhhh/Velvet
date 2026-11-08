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
    /// The native scrubber and skip buttons both arrive as a relative jump in seconds.
    var onSkip: ((Double) -> Void)?
    var onSkipToLive: (() -> Void)?
    /// PiP closed (via its own buttons or `exit()`); the caller moves the video back inline.
    var onClosed: (() -> Void)?
    /// The user pressed PiP's "return to app" button: bring the app's window forward.
    var onRestoreRequested: (() -> Void)?

    /// Why PiP is closing: our own exit(), the X button, or the restore button.
    private var closingBecauseOfExit = false
    private var stopPressed = false
    /// Between pipWillClose and pipDidClose: the closing animation is running.
    private var isClosing = false
    private var restoreSignalled = false

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
        // Already animating closed (e.g. the restore button): a second dismiss would fight it.
        if isClosing { return }
        closingBecauseOfExit = true
        if let window, let rect {
            pip.setValue(window, forKey: "replacementWindow")
            pip.setValue(NSValue(rect: rect), forKey: "replacementRect")
        }
        pip.dismiss(content)
    }

    private var isRestore: Bool { !closingBecauseOfExit && !stopPressed }

    /// Closing has begun. For the restore button, switch to the app *now* so the Space slide
    /// and PiP's fly-back animation run together instead of one after the other.
    private func willClose() {
        isClosing = true
        if isRestore && !restoreSignalled {
            restoreSignalled = true
            onRestoreRequested?()
        }
    }

    private func finish() {
        guard isActive else { return }
        let restore = isRestore
        isActive = false
        startedAutomatically = false
        closingBecauseOfExit = false
        stopPressed = false
        isClosing = false
        pip = nil
        content = nil
        log.info("Left PiP\(restore ? " (restore to app)" : "", privacy: .public)")
        onClosed?()
        // Fallback if the framework skipped pipWillClose.
        if restore && !restoreSignalled { onRestoreRequested?() }
        restoreSignalled = false
    }

    #if DEBUG
    /// Discovery aid: log every optional delegate method PIP.framework asks about.
    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        let name = NSStringFromSelector(aSelector)
        if name.lowercased().contains("pip") || name.lowercased().contains("skip") || name.lowercased().contains("seek") {
            Logger(subsystem: "com.subhash.Velvet", category: "PiP").debug("PIP asks delegate: \(name, privacy: .public)")
        }
        return super.responds(to: aSelector)
    }

    /// Catches messages sent without a responds(to:) check, so their names show up too.
    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        Logger(subsystem: "com.subhash.Velvet", category: "PiP").debug("PIP sent unhandled: \(NSStringFromSelector(aSelector), privacy: .public)")
        return super.forwardingTarget(for: aSelector)
    }

    /// Debug: simulate the system's skip message (what scrubbing/skip buttons send).
    func debugSimulateSkip(_ seconds: Double) {
        guard let pip else { return }
        let sel = NSSelectorFromString("_pipActionSkipInterval:")
        guard let m = class_getInstanceMethod(type(of: pip), sel) else { log.info("no _pipActionSkipInterval:"); return }
        typealias Fn = @convention(c) (NSObject, Selector, Double) -> Void
        log.info("Simulating skip \(seconds, privacy: .public)s")
        unsafeBitCast(method_getImplementation(m), to: Fn.self)(pip, sel, seconds)
    }
    #endif

    /// Tells the system PiP window the timeline, so it can show its native progress/scrubber.
    func updatePlayback(duration: Double, elapsed: Double, rate: Double, playing: Bool, live: Bool) {
        guard let pip else { return }
        let sel = NSSelectorFromString("updatePlaybackStateUsingBlock:")
        guard let method = class_getInstanceMethod(type(of: pip), sel) else { return }
        let block: @convention(block) (NSObject) -> Void = { state in
            // PIPContentType: 1 = VideoOnDemand (seekable scrubber), 2 = LiveBroadcast.
            // Left at 0 ("unspecified"), the system shows progress but won't let you scrub.
            state.setValue(live ? 2 : 1, forKey: "contentType")
            state.setValue(false, forKey: "requiresLinearPlayback")
            if !live, duration > 0 {
                state.setValue(duration, forKey: "contentDuration")
            }
            // setPlaybackRate:elapsedTime:timeControlStatus: — (double, double, long)
            let s2 = NSSelectorFromString("setPlaybackRate:elapsedTime:timeControlStatus:")
            if let m = class_getInstanceMethod(type(of: state), s2) {
                typealias Fn = @convention(c) (NSObject, Selector, Double, Double, Int) -> Void
                unsafeBitCast(method_getImplementation(m), to: Fn.self)(state, s2, playing ? rate : 0, elapsed, playing ? 2 : 0)
            }
        }
        typealias Call = @convention(c) (NSObject, Selector, AnyObject) -> Void
        unsafeBitCast(method_getImplementation(method), to: Call.self)(pip, sel, block as AnyObject)
    }

    // MARK: - PIPViewControllerDelegate (informal; selector names as used by IINA)

    @objc func pipShouldClose(_ pip: NSViewController) -> Bool { true }
    @objc func pipWillClose(_ pip: NSViewController) { willClose() }
    @objc func pipDidClose(_ pip: NSViewController) { finish() }
    /// Scrubbing and the ±skip buttons (selector discovered from PIP.framework's delegate checks).
    @objc(pipAction:skipInterval:) func pipAction(_ pip: NSViewController, skipInterval: Double) {
        log.info("PiP skip \(skipInterval, privacy: .public)s")
        onSkip?(skipInterval)
    }
    @objc(pipAction:setPlaying:) func pipAction(_ pip: NSViewController, setPlaying playing: Bool) {
        playing ? onPlay?() : onPause?()
    }
    @objc func pipActionSkipToLive(_ pip: NSViewController) { onSkipToLive?() }
    @objc func pipActionPlay(_ pip: NSViewController) { onPlay?() }
    @objc func pipActionPause(_ pip: NSViewController) { onPause?() }
    /// The X button: pause and close, without pulling the user back to the app.
    @objc func pipActionStop(_ pip: NSViewController) {
        stopPressed = true
        onPause?()
    }
}
