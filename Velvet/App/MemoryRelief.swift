import Foundation

/// Hands freed heap pages back to the OS.
///
/// Parsing a big InnerTube response (Home is ~2.4 MB of JSON) briefly builds large object
/// trees. After they're freed, the allocator keeps those pages dirty for reuse, so they still
/// count against Velvet's memory until the system is under pressure. Asking for relief after
/// such bursts returns them right away; it's cheap and only touches memory that's already free.
nonisolated enum MemoryRelief {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: DispatchWorkItem?

    /// Coalesces bursts (several feeds/pages loading at once) into one relief pass.
    static func soon() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "VelvetNoRelief") { return } // for A/B measurement
        #endif
        lock.lock(); defer { lock.unlock() }
        pending?.cancel()
        let work = DispatchWorkItem { malloc_zone_pressure_relief(nil, 0) }
        pending = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
