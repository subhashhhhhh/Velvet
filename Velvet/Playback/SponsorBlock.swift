import Foundation
import CryptoKit
import SwiftUI
import OSLog

nonisolated struct SponsorSegment: Identifiable, Hashable, Sendable {
    let id: String
    let category: SponsorCategory
    let start: Double
    let end: Double

    func contains(_ t: Double) -> Bool { t >= start && t < end }
}

/// Fetches crowd-sourced segments from the SponsorBlock API.
nonisolated enum SponsorBlockAPI {
    /// Uses the k-anonymity endpoint: only the first 4 hex chars of sha256(videoId) leave the Mac.
    static func segments(for videoId: String, categories: [SponsorCategory], server: String) async throws -> [SponsorSegment] {
        guard !categories.isEmpty else { return [] }
        let prefix = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4)
        let cats = "[" + categories.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
        var components = URLComponents(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/skipSegments/\(prefix)")
        components?.queryItems = [
            URLQueryItem(name: "categories", value: cats),
            URLQueryItem(name: "actionTypes", value: "[\"skip\"]"),
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Velvet", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        // 404 means "no segments for any video with this prefix".
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        let json = try JSON(data: data)
        guard let entry = json.array.first(where: { $0["videoID"].string == videoId }) else { return [] }
        return entry["segments"].array.compactMap { s in
            guard let uuid = s["UUID"].string,
                  let category = s["category"].string.flatMap(SponsorCategory.init(rawValue:)),
                  let start = s["segment"][0].double, let end = s["segment"][1].double, end > start else { return nil }
            return SponsorSegment(id: uuid, category: category, start: start, end: end)
        }
        .sorted { $0.start < $1.start }
    }
}

extension SponsorCategory {
    /// SponsorBlock's conventional category colors.
    var color: Color {
        switch self {
        case .sponsor: Color(red: 0.00, green: 0.83, blue: 0.00)
        case .selfpromo: Color(red: 1.00, green: 1.00, blue: 0.00)
        case .interaction: Color(red: 0.80, green: 0.00, blue: 1.00)
        case .intro: Color(red: 0.00, green: 1.00, blue: 1.00)
        case .outro: Color(red: 0.01, green: 0.01, blue: 0.93)
        case .preview: Color(red: 0.00, green: 0.56, blue: 0.84)
        case .music_offtopic: Color(red: 1.00, green: 0.60, blue: 0.00)
        case .filler: Color(red: 0.45, green: 0.00, blue: 1.00)
        }
    }

    var shortLabel: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfpromo: "Self-Promotion"
        case .interaction: "Interaction Reminder"
        case .intro: "Intro"
        case .outro: "Outro"
        case .preview: "Preview"
        case .music_offtopic: "Non-Music Section"
        case .filler: "Filler"
        }
    }
}

/// Watches playback time and applies each segment's configured action.
@Observable
final class SponsorSkipper {
    private(set) var segments: [SponsorSegment] = []
    /// A segment awaiting the user's "Skip" click (action = ask).
    private(set) var offered: SponsorSegment?
    /// The most recent automatic skip, shown briefly with Undo.
    private(set) var lastSkip: SponsorSegment?

    @ObservationIgnored private var handled = Set<String>()
    @ObservationIgnored private var lastTime: Double = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private let actions: (SponsorCategory) -> SponsorAction
    @ObservationIgnored private let showNotice: Bool
    @ObservationIgnored private let seek: (Double) -> Void

    init(actions: @escaping (SponsorCategory) -> SponsorAction, showNotice: Bool, seek: @escaping (Double) -> Void) {
        self.actions = actions
        self.showNotice = showNotice
        self.seek = seek
    }

    func setSegments(_ segments: [SponsorSegment]) {
        self.segments = segments
    }

    func timeChanged(_ t: Double) {
        defer { lastTime = t }
        // Rewinding before a segment re-arms it.
        if t < lastTime - 1 {
            for s in segments where t < s.start { handled.remove(s.id) }
        }
        guard let segment = segments.first(where: { $0.contains(t) }) else {
            if offered != nil { offered = nil }
            return
        }
        switch actions(segment.category) {
        case .skip where !handled.contains(segment.id):
            handled.insert(segment.id)
            Logger(subsystem: "com.subhash.Velvet", category: "Player")
                .info("SponsorBlock: skipped \(segment.category.rawValue, privacy: .public) \(segment.start, privacy: .public)→\(segment.end, privacy: .public) at \(t, privacy: .public)")
            seek(segment.end)
            if showNotice { announce(segment) }
        case .ask where !handled.contains(segment.id):
            if offered != segment { offered = segment }
        default:
            break
        }
    }

    func skipOffered() {
        guard let segment = offered else { return }
        handled.insert(segment.id)
        offered = nil
        seek(segment.end)
    }

    /// Jumps back to the start of the last skipped segment and lets it play.
    func undoLastSkip() {
        guard let segment = lastSkip else { return }
        lastSkip = nil
        handled.insert(segment.id)
        seek(segment.start)
    }

    private func announce(_ segment: SponsorSegment) {
        lastSkip = segment
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { lastSkip = nil }
        }
    }
}
