import Foundation
import OSLog

/// Polls a live stream's chat and reveals each batch gradually, the way YouTube does:
/// a response covers the next several seconds, so dumping it all at once looks jumpy.
@Observable
final class LiveChatModel {
    private(set) var messages: [LiveChatMessage] = []
    private(set) var isConnected = false
    private(set) var error: String?

    @ObservationIgnored private let client: InnerTubeClient
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [LiveChatMessage] = []
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "LiveChat")
    private static let limit = 150

    init(client: InnerTubeClient) { self.client = client }

    func start(token: String) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.poll(from: token) }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        revealTask?.cancel(); revealTask = nil
        isConnected = false
    }

    private func poll(from first: String) async {
        var token: String? = first
        var failures = 0
        while let current = token, !Task.isCancelled {
            do {
                let json = try await client.post("live_chat/get_live_chat", ["continuation": .string(current)])
                let page = LiveChatParser.page(from: json)
                isConnected = true
                error = nil
                failures = 0
                apply(page)
                token = page.continuation
                try await Task.sleep(for: page.pollAfter)
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                log.error("Live chat poll failed: \(error.localizedDescription, privacy: .public)")
                if failures >= 4 { self.error = "Chat disconnected."; isConnected = false; return }
                try? await Task.sleep(for: .seconds(3 * failures))
            }
        }
    }

    private func apply(_ page: LiveChatPage) {
        if !page.removedIds.isEmpty {
            let gone = Set(page.removedIds)
            messages.removeAll { gone.contains($0.id) }
            pending.removeAll { gone.contains($0.id) }
        }
        let fresh = page.added.filter { seen.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        pending += fresh
        // Spread this batch over most of the time until the next poll.
        let window = Double(page.pollAfter.components.seconds) * 0.9
        let gap = max(0.05, min(1.0, window / Double(max(pending.count, 1))))
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            while let self, !self.pending.isEmpty, !Task.isCancelled {
                self.reveal(self.pending.removeFirst())
                try? await Task.sleep(for: .seconds(gap))
            }
        }
    }

    private func reveal(_ m: LiveChatMessage) {
        messages.append(m)
        if messages.count > Self.limit { messages.removeFirst(messages.count - Self.limit) }
        if seen.count > 2000 { seen = Set(messages.map(\.id)) }
    }
}
