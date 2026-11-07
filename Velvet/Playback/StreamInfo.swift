import Foundation
import VideoToolbox

/// One downloadable stream as reported by yt-dlp.
nonisolated struct StreamFormat: Hashable, Sendable {
    let id: String
    let url: URL
    let ext: String?
    let protocolName: String
    let height: Int?
    let fps: Double?
    let vcodec: String?
    let acodec: String?
    /// Average bitrate in kbit/s.
    let bitrate: Double?
    let language: String?
    let isDefaultAudio: Bool
    /// "DRC" = YouTube's dynamic-range-compressed (stable volume) variant of an audio track.
    let isDRC: Bool
    /// Headers yt-dlp says the URL must be fetched with (notably User-Agent).
    let httpHeaders: [String: String]

    var hasVideo: Bool { vcodec.map { $0 != "none" } ?? false }
    var hasAudio: Bool { acodec.map { $0 != "none" } ?? false }
    var isHLS: Bool { protocolName.hasPrefix("m3u8") }

    var codecFamily: VideoCodec? {
        guard let v = vcodec?.lowercased() else { return nil }
        if v.hasPrefix("av01") { return .av1 }
        if v.hasPrefix("vp9") || v.hasPrefix("vp09") { return .vp9 }
        if v.hasPrefix("avc") || v.hasPrefix("h264") { return .h264 }
        return nil
    }
}

/// Everything needed to play a video, resolved by yt-dlp.
nonisolated struct StreamInfo: Sendable {
    let videoId: String
    let title: String
    let channel: String?
    let duration: Double?
    let isLive: Bool
    let formats: [StreamFormat]
    /// Links stop working after this (YouTube's `expire` parameter).
    let expires: Date

    var isExpired: Bool { Date() > expires.addingTimeInterval(-10 * 60) }

    struct Selection: Sendable, Equatable {
        let video: StreamFormat
        /// Nil when `video` already contains audio (muxed or HLS).
        let audio: StreamFormat?
    }

    /// Picks the streams to play for the given preferences.
    func select(quality: VideoQuality, codec: VideoCodec) -> Selection? {
        let maxHeight = quality.maxHeight ?? .max

        if isLive || !formats.contains(where: { $0.hasVideo && !$0.hasAudio && !$0.isHLS }) {
            // Live (and the rare HLS-only video): HLS variants carry audio and video together.
            let hls = formats.filter { $0.isHLS && $0.hasVideo }
            let pick = hls.filter { ($0.height ?? 0) <= maxHeight }.max(by: Self.byQuality)
                ?? hls.min(by: { ($0.height ?? 0) < ($1.height ?? 0) })
            if let pick { return Selection(video: pick, audio: nil) }
        }

        let videoOnly = formats.filter { $0.hasVideo && !$0.hasAudio && !$0.isHLS }
        let order = Self.codecPreference(codec)
        let withinCap = videoOnly.filter { ($0.height ?? 0) <= maxHeight }
        let pool = withinCap.isEmpty ? videoOnly : withinCap
        // Highest resolution first; among equals, the preferred codec; then fps, bitrate.
        let video = pool.max { a, b in
            if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) < (b.height ?? 0) }
            let ra = order.firstIndex(of: a.codecFamily ?? .h264) ?? order.count
            let rb = order.firstIndex(of: b.codecFamily ?? .h264) ?? order.count
            if ra != rb { return ra > rb }
            return Self.byQuality(a, b)
        }
        guard let video else {
            // Fall back to a muxed (audio+video) progressive stream.
            let muxed = formats.filter { $0.hasVideo && $0.hasAudio && !$0.isHLS }.max(by: Self.byQuality)
            return muxed.map { Selection(video: $0, audio: nil) }
        }
        return Selection(video: video, audio: bestAudio())
    }

    /// Original-language track, non-DRC, Opus preferred, highest bitrate.
    func bestAudio() -> StreamFormat? {
        let audio = formats.filter { $0.hasAudio && !$0.hasVideo && !$0.isHLS }
        let defaults = audio.filter(\.isDefaultAudio)
        let pool = (defaults.isEmpty ? audio : defaults)
        let nonDRC = pool.filter { !$0.isDRC }
        return (nonDRC.isEmpty ? pool : nonDRC).max { a, b in
            let oa = a.acodec?.hasPrefix("opus") == true, ob = b.acodec?.hasPrefix("opus") == true
            if oa != ob { return !oa }
            return (a.bitrate ?? 0) < (b.bitrate ?? 0)
        }
    }

    private static func byQuality(_ a: StreamFormat, _ b: StreamFormat) -> Bool {
        if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) < (b.height ?? 0) }
        if (a.fps ?? 0) != (b.fps ?? 0) { return (a.fps ?? 0) < (b.fps ?? 0) }
        return (a.bitrate ?? 0) < (b.bitrate ?? 0)
    }

    /// Codec order for a preference. `.auto` prefers whatever this Mac decodes in hardware.
    static func codecPreference(_ codec: VideoCodec) -> [VideoCodec] {
        switch codec {
        case .av1: [.av1, .vp9, .h264]
        case .vp9: [.vp9, .av1, .h264]
        case .h264: [.h264, .vp9, .av1]
        case .auto: hardwareAutoOrder
        }
    }

    static let hardwareAutoOrder: [VideoCodec] = {
        // VP9/AV1 are "supplemental" decoders: VideoToolbox only reports them after registration.
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        var order: [VideoCodec] = []
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) { order.append(.av1) }
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9) { order.append(.vp9) }
        order.append(.h264)
        for c in [VideoCodec.vp9, .av1] where !order.contains(c) { order.append(c) }
        return order
    }()
}

// MARK: - Parsing yt-dlp's -J output

extension StreamInfo {
    nonisolated init?(ytdlp json: JSON) {
        guard let id = json["id"].string else { return nil }
        videoId = id
        title = json["title"].string ?? ""
        channel = json["channel"].string ?? json["uploader"].string
        duration = json["duration"].double
        isLive = json["is_live"].bool ?? false

        var earliestExpiry: Double = .infinity
        formats = json["formats"].array.compactMap { f in
            guard let id = f["format_id"].string,
                  let urlString = f["url"].string, let url = URL(string: urlString) else { return nil }
            if let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "expire" })?.value.flatMap(Double.init) {
                earliestExpiry = min(earliestExpiry, expire)
            }
            let note = (f["format_note"].string ?? "").lowercased()
            return StreamFormat(
                id: id,
                url: url,
                ext: f["ext"].string,
                protocolName: f["protocol"].string ?? "https",
                height: f["height"].int,
                fps: f["fps"].double,
                vcodec: f["vcodec"].string,
                acodec: f["acodec"].string,
                bitrate: f["tbr"].double,
                language: f["language"].string,
                // yt-dlp ranks the original track highest via language_preference.
                isDefaultAudio: note.contains("default") || note.contains("original") || (f["language_preference"].int ?? 0) >= 10,
                isDRC: id.hasSuffix("-drc") || note.contains("drc"),
                httpHeaders: (f["http_headers"].object ?? [:]).compactMapValues(\.string)
            )
        }
        expires = earliestExpiry.isFinite
            ? Date(timeIntervalSince1970: earliestExpiry)
            : Date().addingTimeInterval(isLive ? 30 * 60 : 5 * 60 * 60)
    }
}
