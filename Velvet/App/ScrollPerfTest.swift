#if DEBUG
import AppKit
import OSLog
import QuartzCore

/// `-VelvetScrollPerfTest YES` (alone for Home, with `-VelvetPlay` for the watch page): at 12 s,
/// scrolls the page like a trackpad, one scroll event per display refresh (2 s down, 2 s up),
/// and logs how regularly the refreshes came (category `Test`). A refresh that comes late
/// means the main thread was busy: that's the stutter you see.
@MainActor
final class ScrollPerfTest: NSObject {
    private static var running: ScrollPerfTest?
    private let scrollView: NSScrollView
    private let label: String
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var frameDuration: CFTimeInterval = 1 / 60
    private var step = 0
    /// `-VelvetScrollFrames` refreshes each way (default 120) and `-VelvetScrollStep` points per refresh (default 14).
    private let perLeg = UserDefaults.standard.integer(forKey: "VelvetScrollFrames") > 0 ? UserDefaults.standard.integer(forKey: "VelvetScrollFrames") : 120
    private let stepPoints = UserDefaults.standard.integer(forKey: "VelvetScrollStep") > 0 ? Int32(UserDefaults.standard.integer(forKey: "VelvetScrollStep")) : 14
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Test")

    private init(scrollView: NSScrollView, label: String) {
        self.scrollView = scrollView
        self.label = label
    }

    static func start(in window: NSWindow, label: String) {
        guard running == nil, let content = window.contentView,
              let sv = AppModel.largestScrollView(in: content, containing: NSPoint(x: content.bounds.midX, y: content.bounds.midY))
        else { return }
        let test = ScrollPerfTest(scrollView: sv, label: label)
        running = test
        let link = content.displayLink(target: test, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        test.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        frameDuration = link.duration > 0 ? link.duration : frameDuration
        let leg = step / perLeg, within = step % perLeg
        // Phases as a trackpad sends them: began, changed…, ended, for each direction.
        let phase: Int64 = within == 0 ? 1 : (within == perLeg - 1 ? 4 : 2)
        let dy: Int32 = leg == 0 ? -stepPoints : stepPoints
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            if let event = NSEvent(cgEvent: cg) { scrollView.scrollWheel(with: event) }
        }
        step += 1
        if step == perLeg { log.info("Test: scrolled to \(Int(self.scrollView.contentView.bounds.origin.y)) pt") }
        if step >= perLeg * 2 { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        Self.running = nil
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        guard !gaps.isEmpty else { return }
        let span = (stamps.last ?? 0) - (stamps.first ?? 0)
        let hitches = gaps.filter { $0 > frameDuration * 1.5 }
        let lost = gaps.reduce(0) { $0 + max(0, $1 - frameDuration) }
        let sorted = gaps.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let summary = "\(label): \(gaps.count) frames in \(String(format: "%.2f", span)) s = \(String(format: "%.1f", Double(gaps.count) / span)) fps (display \(Int((1 / frameDuration).rounded())) Hz), \(hitches.count) hitches, \(String(format: "%.0f", lost * 1000)) ms late in all, p95 \(String(format: "%.1f", p95 * 1000)) ms, worst \(String(format: "%.1f", (sorted.last ?? 0) * 1000)) ms"
        log.info("Test: scroll perf \(summary, privacy: .public)")
        // Memory after the scroll, and how far the watch page's lists got.
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) }
        }
        let footprint = kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_000_000) : -1
        let lists = AppModel.testWatchCounts?() ?? "-"
        log.info("Test: after scroll: \(footprint) MB, \(lists, privacy: .public)")
    }
}

#endif

#if DEBUG
/// `-VelvetFrameMonitor YES`: logs every 2 s how regularly display refreshes reached the main
/// thread (category `Test`), for measuring real trackpad scrolling by hand. Quiet while
/// nothing changes on screen.
@MainActor
final class FrameMonitor: NSObject {
    private static var shared: FrameMonitor?
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var frameDuration: CFTimeInterval = 1 / 60
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Test")

    static func start(in window: NSWindow) {
        guard shared == nil, let view = window.contentView else { return }
        let monitor = FrameMonitor()
        let link = view.displayLink(target: monitor, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        monitor.link = link
        shared = monitor
    }

    @objc private func tick(_ link: CADisplayLink) {
        frameDuration = link.duration > 0 ? link.duration : frameDuration
        stamps.append(link.timestamp)
        guard let first = stamps.first, link.timestamp - first >= 2 else { return }
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        stamps = [link.timestamp]
        let hitches = gaps.filter { $0 > frameDuration * 1.5 }
        let worst = gaps.max() ?? 0
        let summary = "\(gaps.count) frames, \(hitches.count) late, worst \(String(format: "%.0f", worst * 1000)) ms (display \(Int((1 / frameDuration).rounded())) Hz)"
        log.info("Test: frames \(summary, privacy: .public)")
    }
}
#endif
