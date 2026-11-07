import Foundation
import OSLog

/// An endless, swipeable run of Shorts: seeded from one you clicked, or chosen by YouTube.
@Observable
final class ShortsSequence {
    private(set) var items: [Video] = []
    private(set) var index = 0
    private(set) var isLoading = false
    private(set) var error: String?

    var current: Video? { items.indices.contains(index) ? items[index] : nil }
    var next: Video? { items.indices.contains(index + 1) ? items[index + 1] : nil }
    var canGoBack: Bool { index > 0 }

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private let client: InnerTubeClient
    @ObservationIgnored private let seed: Video?
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "Shorts")

    init(seed: Video?, client: InnerTubeClient) {
        self.seed = seed
        self.client = client
    }

    func start() async {
        guard items.isEmpty, !isLoading else { return }
        if let seed {
            append([seed])
            token = InnerTubeClient.shortsSeed(for: seed.id)
            await loadMore()
        } else {
            isLoading = true
            do {
                let json = try await client.shortsSeedless()
                isLoading = false
                guard let id = json["replacementEndpoint"]["reelWatchEndpoint"]["videoId"].string
                        ?? json["playerResponse"]["videoDetails"]["videoId"].string else {
                    error = "YouTube didn't return any Shorts."
                    return
                }
                // (isLoading already cleared above)
                append([Self.short(id, from: json)])
                token = json["sequenceContinuation"].string
            } catch {
                isLoading = false
                self.error = error.localizedDescription
                return
            }
            // isLoading must be clear here, or loadMore() bails out and there's no "next".
            await loadMore()
        }
    }

    /// Moves by `delta` (±1); fetches more when nearing the end.
    func move(_ delta: Int) {
        let target = index + delta
        guard items.indices.contains(target) else { return }
        index = target
        if items.count - index <= 3 { Task { await loadMore() } }
    }

    func loadMore() async {
        guard let token, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // The first seeded page is just the seed itself, so keep paging until something new arrives.
            var next: String? = token
            for _ in 0..<3 {
                guard let t = next else { break }
                let json = try await client.shortsSequence(t)
                let ids = json["entries"].array.compactMap { $0.first("reelWatchEndpoint")?["videoId"].string }
                next = json["continuationEndpoint"]["continuationCommand"]["token"].string
                let before = items.count
                append(ids.map { Video(id: $0, title: "", kind: .short) })
                if items.count > before { break }
            }
            self.token = next
        } catch {
            log.error("Shorts sequence failed: \(error.localizedDescription, privacy: .public)")
            if items.isEmpty { self.error = error.localizedDescription }
        }
    }

    private func append(_ videos: [Video]) {
        items += videos.filter { seen.insert($0.id).inserted }
    }

    private static func short(_ id: String, from json: JSON) -> Video {
        let details = json["playerResponse"]["videoDetails"]
        return Video(id: id, title: details["title"].string ?? "", kind: .short,
                     channelName: details["author"].string, channelId: details["channelId"].string)
    }
}
