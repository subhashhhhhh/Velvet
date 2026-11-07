import Foundation
import CryptoKit
import OSLog

nonisolated enum DeArrowThumbnailMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off, submitted, random
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Original"
        case .submitted: "Community Submitted"
        case .random: "Submitted, or a Random Frame"
        }
    }
}

/// Community-replaced title/thumbnail for one video.
nonisolated struct DeArrowBranding: Sendable, Equatable {
    var title: String?
    /// Seconds into the video for a replacement frame.
    var thumbnailTime: Double?
}

/// Fetches DeArrow branding (dearrow.ajay.app) with k-anonymity: only a 4-char sha256
/// prefix leaves the Mac, and one response covers every video sharing that prefix.
actor DeArrowService {
    private struct VideoData: Sendable {
        var titles: [(title: String, original: Bool, trusted: Bool)]
        var thumbnails: [(time: Double?, original: Bool, trusted: Bool)]
        var randomTime: Double?
        var duration: Double?
    }

    private var prefixes: [String: [String: VideoData]] = [:]
    private var prefixOrder: [String] = []
    private var inFlight: [String: Task<[String: VideoData], Never>] = [:]
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "DeArrow")
    private static let prefixLimit = 400
    private static let api = "https://sponsor.ajay.app"
    static let thumbnailHost = "https://dearrow-thumb.ajay.app"

    func branding(for videoId: String, duration: Double?, thumbnails mode: DeArrowThumbnailMode) async -> DeArrowBranding? {
        let prefix = Self.prefix(videoId)
        let table: [String: VideoData]
        if let cached = prefixes[prefix] {
            table = cached
        } else if let running = inFlight[prefix] {
            table = await running.value
        } else {
            let task = Task { await Self.fetch(prefix: prefix, log: log) }
            inFlight[prefix] = task
            table = await task.value
            inFlight[prefix] = nil
            store(prefix, table)
        }

        guard let data = table[videoId] else { return nil }
        var result = DeArrowBranding()

        // Best-voted title, unless the community says the original is best.
        if let best = data.titles.first(where: \.trusted), !best.original {
            result.title = Self.clean(best.title)
        }

        switch mode {
        case .off:
            break
        case .submitted, .random:
            if let best = data.thumbnails.first(where: \.trusted) {
                if !best.original { result.thumbnailTime = best.time }
            } else if mode == .random, let r = data.randomTime, let d = data.duration ?? duration, d > 0 {
                result.thumbnailTime = r * d
            }
        }
        return result.title == nil && result.thumbnailTime == nil ? nil : result
    }

    static func thumbnailURL(videoId: String, time: Double) -> URL? {
        URL(string: "\(thumbnailHost)/api/v1/getThumbnail?videoID=\(videoId)&time=\(String(format: "%.3f", time))")
    }

    // MARK: - Internals

    private func store(_ prefix: String, _ table: [String: VideoData]) {
        prefixes[prefix] = table
        prefixOrder.append(prefix)
        if prefixOrder.count > Self.prefixLimit { prefixes[prefixOrder.removeFirst()] = nil }
    }

    private static func prefix(_ videoId: String) -> String {
        String(SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4))
    }

    /// DeArrow marks "don't auto-format this title" with a leading '>'.
    private static func clean(_ title: String) -> String {
        title.hasPrefix(">") ? String(title.dropFirst()).trimmingCharacters(in: .whitespaces) : title
    }

    private static func fetch(prefix: String, log: Logger) async -> [String: VideoData] {
        guard let url = URL(string: "\(api)/api/branding/\(prefix)") else { return [:] }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Velvet", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
            guard case .object(let videos) = try JSON(data: data) else { return [:] }
            var table: [String: VideoData] = [:]
            for (id, v) in videos {
                func trusted(_ x: JSON) -> Bool { (x["locked"].bool ?? false) || (x["votes"].double ?? 0) >= 0 }
                let titles = v["titles"].array.compactMap { t -> (String, Bool, Bool)? in
                    guard let s = t["title"].string, !s.isEmpty else { return nil }
                    return (s, t["original"].bool ?? false, trusted(t))
                }
                let thumbs = v["thumbnails"].array.map { t in
                    (t["timestamp"].double, t["original"].bool ?? false, trusted(t))
                }
                table[id] = VideoData(titles: titles, thumbnails: thumbs,
                                      randomTime: v["randomTime"].double, duration: v["videoDuration"].double)
            }
            return table
        } catch {
            log.debug("Branding fetch failed for \(prefix, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}
