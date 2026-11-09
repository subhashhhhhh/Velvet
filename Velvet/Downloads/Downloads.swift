import Foundation
import OSLog

/// A video saved for offline viewing: its folder's `info.json`. The video and audio streams
/// are kept as YouTube serves them, in separate files (making one file needs ffmpeg, which
/// Velvet doesn't have); mpv plays them together, so downloads play in Velvet only.
nonisolated struct DownloadedVideo: Codable, Sendable, Identifiable, Hashable {
    let id: String
    var title: String
    var channelName: String?
    var channelId: String?
    /// Formatted length ("12:04") and seconds.
    var duration: String?
    var seconds: Double?
    /// "1080p", "1440p (2560×1080)"…
    var resolution: String
    var bytes: Int64
    var downloadedAt: Date
    var video: SavedStream
    var audio: SavedStream?
    var chapters: [SavedChapter]

    struct SavedStream: Codable, Sendable, Hashable {
        var file: String
        var formatId: String
        var ext: String?
        var width: Int?
        var height: Int?
        var tier: Int?
        var fps: Double?
        var vcodec: String?
        var acodec: String?
        var bitrate: Double?
        var isHDR: Bool
    }

    struct SavedChapter: Codable, Sendable, Hashable {
        var start: Double
        var end: Double?
        var title: String
    }
}

/// Downloads videos, one at a time, and keeps the list of downloaded ones.
@Observable
final class Downloads {
    enum Progress: Equatable {
        case waiting
        case downloading(Double)
        case failed(String)
    }

    /// Finished downloads, newest first.
    private(set) var items: [DownloadedVideo] = []
    /// Downloads not finished yet (waiting, running or failed), by video ID.
    private(set) var active: [String: Progress] = [:]

    nonisolated static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "com.subhash.Velvet/Downloads", directoryHint: .isDirectory)

    @ObservationIgnored private let resolver: StreamResolver
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var pending: [Video] = []
    /// The videos of unfinished downloads (for their titles, and to retry).
    @ObservationIgnored private var started: [String: Video] = [:]
    @ObservationIgnored private var running: (id: String, task: Task<Void, Never>)?
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Downloads")

    init(resolver: StreamResolver, preferences: Preferences) {
        self.resolver = resolver
        prefs = preferences
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        items = Self.scan()
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    func isDownloaded(_ id: String) -> Bool { items.contains { $0.id == id } }

    func folder(for id: String) -> URL { Self.root.appending(path: id, directoryHint: .isDirectory) }

    func thumbnail(for id: String) -> URL { folder(for: id).appending(path: "thumbnail.jpg") }

    // MARK: Downloading

    func download(_ video: Video) {
        guard !isDownloaded(video.id), active[video.id] == nil || active[video.id] != .waiting else { return }
        if case .downloading = active[video.id] { return }
        active[video.id] = .waiting
        started[video.id] = video
        pending.append(video)
        startNext()
    }

    /// Tries a failed download again.
    func retry(_ id: String) {
        guard case .failed = active[id], let video = started[id] else { return }
        active[id] = nil
        download(video)
    }

    /// An unfinished download's title.
    func title(for id: String) -> String { started[id]?.title ?? id }

    func cancel(_ id: String) {
        pending.removeAll { $0.id == id }
        if running?.id == id { running?.task.cancel() }
        active[id] = nil
        started[id] = nil
    }

    func remove(_ id: String) {
        cancel(id)
        try? FileManager.default.removeItem(at: folder(for: id))
        items.removeAll { $0.id == id }
    }

    func removeAll() {
        for id in items.map(\.id) + Array(active.keys) { remove(id) }
    }

    private func startNext() {
        guard running == nil, !pending.isEmpty else { return }
        let video = pending.removeFirst()
        active[video.id] = .downloading(0)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await self.perform(video)
                self.items.insert(item, at: 0)
                self.active[video.id] = nil
                self.started[video.id] = nil
                self.log.info("Downloaded \(video.id, privacy: .public): \(item.resolution, privacy: .public), \(item.bytes) bytes")
            } catch is CancellationError {
                self.active[video.id] = nil
            } catch {
                self.log.error("Download of \(video.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.active[video.id] = .failed(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: Self.partial(video.id))
            self.running = nil
            self.startNext()
        }
        running = (video.id, task)
    }

    enum DownloadError: LocalizedError {
        case live, notDownloadable, http(Int)
        var errorDescription: String? {
            switch self {
            case .live: "Live streams can't be downloaded."
            case .notDownloadable: "This video has no streams Velvet can download."
            case .http(403): "YouTube refused the download (HTTP 403). Try again."
            case .http(let code): "YouTube answered HTTP \(code)."
            }
        }
    }

    private static func partial(_ id: String) -> URL { root.appending(path: ".\(id)-partial", directoryHint: .isDirectory) }

    private func perform(_ video: Video) async throws -> DownloadedVideo {
        let info = try await resolver.resolve(video.id)
        guard !info.isLive else { throw DownloadError.live }
        guard let selection = info.select(quality: prefs.quality, codec: prefs.codec, displayLimit: PlayerSession.displayHeightLimit()),
              !selection.video.isHLS else { throw DownloadError.notDownloadable }
        // Fresh links 403 for a few seconds after extraction.
        if let ready = selection.availableAt, ready > .now { try await Task.sleep(for: .seconds(ready.timeIntervalSinceNow)) }

        let fm = FileManager.default
        let temp = Self.partial(video.id)
        try? fm.removeItem(at: temp)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)

        let streams = [selection.video] + (selection.audio.map { [$0] } ?? [])
        let total = max(1, streams.reduce(Int64(0)) { $0 + ($1.contentLength ?? 0) })
        var done: Int64 = 0
        var saved: [DownloadedVideo.SavedStream] = []
        for (index, stream) in streams.enumerated() {
            let name = (index == 0 ? "video" : "audio") + "." + (stream.ext ?? "bin")
            let before = done
            let id = video.id
            let bytes = try await Self.fetch(stream, to: temp.appending(path: name)) { [weak self] received in
                let fraction = min(1, Double(before + received) / Double(total))
                Task { @MainActor in
                    guard let self, case .downloading(let shown) = self.active[id], fraction - shown >= 0.005 || fraction >= 1 else { return }
                    self.active[id] = .downloading(fraction)
                }
            }
            done += bytes
            saved.append(.init(file: name, formatId: stream.id, ext: stream.ext, width: stream.width, height: stream.height,
                               tier: stream.tier, fps: stream.fps, vcodec: stream.vcodec, acodec: stream.acodec,
                               bitrate: stream.bitrate, isHDR: stream.isHDR))
        }

        // The thumbnail, for the Downloads page offline.
        if let (data, response) = try? await URLSession.shared.data(from: video.thumbnail(minWidth: 640)),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            try? data.write(to: temp.appending(path: "thumbnail.jpg"))
        }

        let item = DownloadedVideo(
            id: video.id,
            title: info.title.isEmpty ? video.title : info.title,
            channelName: video.channelName ?? info.channel,
            channelId: video.channelId,
            duration: video.duration,
            seconds: info.duration,
            resolution: selection.video.resolutionLabel.isEmpty ? "Video" : selection.video.resolutionLabel,
            bytes: done,
            downloadedAt: .now,
            video: saved[0],
            audio: saved.count > 1 ? saved[1] : nil,
            chapters: info.chapters.map { .init(start: $0.start, end: $0.end, title: $0.title) }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(item).write(to: temp.appending(path: "info.json"))
        let final = folder(for: video.id)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: temp, to: final)
        return item
    }

    /// Downloads one stream in 10 MB ranges, appending each to `file`: YouTube serves a range
    /// at full speed but slows an open-ended download to ~500 KB/s. Each range goes to disk
    /// (mapped, not held in memory). Returns the bytes written.
    @concurrent
    private nonisolated static func fetch(_ format: StreamFormat, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let chunk: Int64 = 10 << 20
        let total = format.contentLength
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            let end = total.map { min(offset + chunk, $0) - 1 } ?? offset + chunk - 1
            var request = URLRequest(url: format.url, timeoutInterval: 30)
            for (name, value) in format.httpHeaders { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let rangeRequest = request
            let piece: URL
            do {
                // ToolManager's retry treats 5xx and dropped connections as passing (its error
                // type carries the status); a final failure is reported as the download's own.
                piece = try await ToolManager.retrying("Download range of \(format.id)") {
                    let (temp, response) = try await URLSession.shared.download(for: rangeRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 206 || status == 200 else {
                        try? FileManager.default.removeItem(at: temp)
                        throw ToolError.github(status)
                    }
                    return temp
                }
            } catch ToolError.github(let status) {
                throw DownloadError.http(status)
            }
            defer { try? FileManager.default.removeItem(at: piece) }
            let data = try Data(contentsOf: piece, options: .alwaysMapped)
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress(offset)
            if let total, offset >= total { break }
            if total == nil, data.count < chunk { break }
            if data.isEmpty { break }
        }
        return offset
    }

    // MARK: Offline playback

    /// The downloaded streams as a StreamInfo the player can play (local files).
    func localStreams(for id: String) -> StreamInfo? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let base = folder(for: id)
        func format(_ s: DownloadedVideo.SavedStream, video: Bool) -> StreamFormat? {
            let url = base.appending(path: s.file)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var f = StreamFormat(id: s.formatId, url: url, ext: s.ext, protocolName: "file", width: s.width, height: s.height,
                                 qualityLabel: s.tier, audioClass: video ? 0 : 3, fps: s.fps,
                                 vcodec: video ? s.vcodec : "none", acodec: video ? "none" : s.acodec,
                                 bitrate: s.bitrate, language: nil, isDefaultAudio: !video, isDRC: false,
                                 httpHeaders: [:], availableAt: nil)
            f.isHDR = s.isHDR
            return f
        }
        guard let video = format(item.video, video: true) else { return nil }
        let audio = item.audio.flatMap { format($0, video: false) }
        return StreamInfo(localVideo: id, title: item.title, channel: item.channelName, duration: item.seconds,
                          formats: [video] + (audio.map { [$0] } ?? []),
                          chapters: item.chapters.map { Chapter(start: $0.start, end: $0.end, title: $0.title) })
    }

    /// The downloaded video as a Video for the grid (local thumbnail).
    func asVideo(_ item: DownloadedVideo) -> Video {
        var video = Video(id: item.id, title: item.title)
        video.channelName = item.channelName
        video.channelId = item.channelId
        video.duration = item.duration
        let thumb = thumbnail(for: item.id)
        if FileManager.default.fileExists(atPath: thumb.path) {
            video.thumbnails = [Thumbnail(url: thumb, width: 640, height: 360)]
        }
        return video
    }

    private static func scan() -> [DownloadedVideo] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "info.json")) else { return nil }
            return try? decoder.decode(DownloadedVideo.self, from: data)
        }
        .sorted { $0.downloadedAt > $1.downloadedAt }
    }
}

extension StreamInfo {
    /// A downloaded video's streams (local files): never expire, no captions.
    nonisolated init(localVideo id: String, title: String, channel: String?, duration: Double?,
                     formats: [StreamFormat], chapters: [Chapter]) {
        videoId = id
        self.title = title
        self.channel = channel
        self.duration = duration
        isLive = false
        self.formats = formats
        expires = .distantFuture
        self.chapters = chapters
    }
}
