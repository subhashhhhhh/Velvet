import Foundation
import Network
import OSLog

/// Serves one stream to mpv on 127.0.0.1 while downloading it from several YouTube links at
/// once. YouTube paces each client's links to its estimate of your bandwidth (about half a
/// 30 Mbit/s line), but different clients are paced separately: two links to the same file
/// together come close to the connection's real speed. mpv asks for byte ranges as usual; each
/// range is fetched in 2 MB pieces, alternating between the links, and sent back in order.
///
/// Memory stays small: each link works at most a few pieces ahead of what mpv has received.
nonisolated final class SplitStreamServer: @unchecked Sendable {
    static let shared = SplitStreamServer()

    struct Source: Sendable {
        let url: URL
        let headers: [String: String]
    }

    private struct Stream {
        let sources: [Source]
        let length: Int64
        let contentType: String
    }

    private let queue = DispatchQueue(label: "com.subhash.Velvet.split-stream")
    private var listener: NWListener?
    private var port: UInt16?
    private var streams: [String: Stream] = [:]
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "SplitStream")
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 20
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }()

    static let pieceSize: Int64 = 2 * 1024 * 1024
    /// How many pieces a link may fetch beyond what's been sent to mpv.
    static let lookahead = 3

    /// A local URL that mpv can play, backed by `sources` (the same file from different
    /// clients). Nil if the server can't start or the length isn't known.
    func url(for sources: [Source], length: Int64, contentType: String) -> URL? {
        guard sources.count > 1, length > 0, let port = startIfNeeded() else { return nil }
        let id = UUID().uuidString
        queue.sync {
            // Old streams' links expire within hours anyway; keep the table small.
            if streams.count > 8 { streams.removeAll() }
            streams[id] = Stream(sources: sources, length: length, contentType: contentType)
        }
        return URL(string: "http://127.0.0.1:\(port)/s/\(id)")
    }

    private func startIfNeeded() -> UInt16? {
        queue.sync {
            if let port { return port }
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
                params.acceptLocalOnly = true
                let listener = try NWListener(using: params)
                let ready = DispatchSemaphore(value: 0)
                listener.stateUpdateHandler = { state in
                    if case .ready = state { ready.signal() }
                    if case .failed = state { ready.signal() }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.queue.async { self?.accept(connection) }
                }
                // Its own queue: we wait for it to be ready while holding `queue`.
                listener.start(queue: DispatchQueue(label: "com.subhash.Velvet.split-stream.listener"))
                guard ready.wait(timeout: .now() + 2) == .success, let p = listener.port?.rawValue else {
                    listener.cancel()
                    return nil
                }
                self.listener = listener
                port = p
                log.info("Split-stream server on port \(p)")
                return p
            } catch {
                log.error("Split-stream server failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    // MARK: Requests

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if done || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[1].hasPrefix("/s/"),
              let stream = streams[String(parts[1].dropFirst(3))] else {
            respond(connection, status: "404 Not Found", headers: [:], close: true)
            return
        }
        var start: Int64 = 0
        var end = stream.length - 1
        var ranged = false
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = range.split(separator: "=", maxSplits: 1).last {
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let s = bounds.first.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }) { start = s; ranged = true }
            if bounds.count > 1, let e = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) { end = min(e, stream.length - 1) }
        }
        guard start <= end else {
            respond(connection, status: "416 Range Not Satisfiable",
                    headers: ["Content-Range": "bytes */\(stream.length)"], close: true)
            return
        }
        var headers = ["Content-Type": stream.contentType, "Accept-Ranges": "bytes",
                       "Content-Length": "\(end - start + 1)", "Connection": "close"]
        if ranged { headers["Content-Range"] = "bytes \(start)-\(end)/\(stream.length)" }
        respond(connection, status: ranged ? "206 Partial Content" : "200 OK", headers: headers, close: false)
        let transfer = Transfer(stream: stream, start: start, end: end, connection: connection,
                                session: session, queue: queue, log: log)
        transfer.run()
    }

    private func respond(_ connection: NWConnection, status: String, headers: [String: String], close: Bool) {
        var text = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        text += "\r\n"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    // MARK: One range, fetched in pieces from every link

    private final class Transfer: @unchecked Sendable {
        let stream: Stream
        let connection: NWConnection
        let session: URLSession
        let queue: DispatchQueue
        let log: Logger
        let pieces: [ClosedRange<Int64>]

        /// Fetched pieces waiting to be sent in order, by index.
        var ready: [Int: Data] = [:]
        /// The next piece to send to mpv.
        var nextToSend = 0
        /// The next piece nobody has started.
        var nextToFetch = 0
        var tasks: [URLSessionDataTask] = []
        var finished = false
        var sending = false

        init(stream: Stream, start: Int64, end: Int64, connection: NWConnection, session: URLSession,
             queue: DispatchQueue, log: Logger) {
            self.stream = stream
            self.connection = connection
            self.session = session
            self.queue = queue
            self.log = log
            pieces = stride(from: start, through: end, by: Int(SplitStreamServer.pieceSize)).map {
                $0...min($0 + SplitStreamServer.pieceSize - 1, end)
            }
            // Strong on purpose: the connection keeps the transfer alive until it ends
            // (finish/stop clear the handler).
            connection.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed: self.stop()
                default: break
                }
            }
        }

        func run() {
            for i in stream.sources.indices { fetchNext(source: i) }
        }

        /// Each link fetches one piece at a time, staying within the lookahead.
        private func fetchNext(source: Int) {
            guard !finished, nextToFetch < pieces.count, nextToFetch < nextToSend + SplitStreamServer.lookahead else { return }
            let index = nextToFetch
            nextToFetch += 1
            fetch(index, from: source, attempt: 0)
        }

        private func fetch(_ index: Int, from source: Int, attempt: Int) {
            let src = stream.sources[source]
            var request = URLRequest(url: src.url)
            for (k, v) in src.headers { request.setValue(v, forHTTPHeaderField: k) }
            let range = pieces[index]
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                self.queue.async {
                    guard !self.finished else { return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if let data, (200..<300).contains(status), Int64(data.count) == Int64(range.count) {
                        self.ready[index] = data
                        self.sendReady()
                        self.fetchNext(source: source)
                    } else if attempt < 2 {
                        // That link failed (expired, refused, cut off): try the piece on another.
                        let other = (source + 1) % self.stream.sources.count
                        self.log.info("Piece \(index) failed on link \(source) (HTTP \(status)); retrying on link \(other)")
                        self.fetch(index, from: other, attempt: attempt + 1)
                    } else {
                        self.log.error("Piece \(index) failed on every link; closing the range")
                        self.stop()
                    }
                }
            }
            tasks.append(task)
            task.resume()
        }

        /// Sends the pieces that are next in order; each send's completion pulls the next.
        private func sendReady() {
            guard !finished, !sending, let data = ready.removeValue(forKey: nextToSend) else { return }
            sending = true
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.sending = false
                    guard error == nil else { self.stop(); return }
                    self.nextToSend += 1
                    if self.nextToSend == self.pieces.count {
                        self.finished = true
                        self.connection.stateUpdateHandler = nil
                        self.connection.cancel()
                        return
                    }
                    for i in self.stream.sources.indices { self.fetchNext(source: i) }
                    self.sendReady()
                }
            })
        }

        /// mpv moved on (seek, stop) or a piece failed everywhere.
        func stop() {
            queue.async {
                guard !self.finished else { return }
                self.finished = true
                self.tasks.forEach { $0.cancel() }
                self.ready.removeAll()
                self.connection.stateUpdateHandler = nil
                self.connection.cancel()
            }
        }
    }
}
