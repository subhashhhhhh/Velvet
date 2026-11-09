import Foundation
import OSLog

/// Your YouTube search history as Google My Activity keeps it: every search from every device,
/// newest first, the list the YouTube apps show. YouTube's own suggestion service, which is all
/// a web sign-in can ask, returns only a few searches of its own choosing.
///
/// My Activity is a page, not an API. Opening it with the account's cookies first sends us
/// through accounts.google.com, which answers with a form that posts a one-time token to
/// `myactivity.google.com/accounts/SetOSID` (a browser submits it with JavaScript); that sets
/// the page's own session cookie. The page then lists recent activity as HTML, and each search
/// links to its `youtube.com/results?search_query=` page. Only those links are read.
actor MyActivitySearches {
    private let account: YouTubeSession
    private var urlSession: URLSession?
    private var cached: (at: Date, searches: [String])?
    private var inFlight: Task<[String], Never>?
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "MyActivity")

    /// The page is about 1.2 MB, so it's read at most this often.
    private static let lifetime: TimeInterval = 5 * 60
    private static let pageURL = URL(string: "https://myactivity.google.com/product/youtube?hl=en")!
    // Google serves the full page only to a browser it recognizes.
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    init(account: YouTubeSession) {
        self.account = account
    }

    /// Recent searches, newest first, without repeats. Empty when the page can't be read.
    func recent() async -> [String] {
        if let cached, Date().timeIntervalSince(cached.at) < Self.lifetime { return cached.searches }
        if let inFlight { return await inFlight.value }
        let task = Task { await self.load() }
        inFlight = task
        let searches = await task.value
        inFlight = nil
        cached = (.now, searches)
        return searches
    }

    /// After a search in Velvet, so the next look includes it.
    func invalidate() { cached = nil }

    private func load() async -> [String] {
        do {
            let session = await session()
            var (data, response) = try await session.data(for: request(Self.pageURL))
            if let form = Self.osidForm(in: data) {
                var post = request(form.action)
                post.httpMethod = "POST"
                post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                var body = URLComponents()
                body.queryItems = form.fields.map { URLQueryItem(name: $0.key, value: $0.value) }
                // URLComponents leaves "+" alone; in a form body it would read as a space.
                post.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
                (data, response) = try await session.data(for: post)
            }
            let searches = Self.searches(in: data)
            let host = (response as? HTTPURLResponse)?.url?.host() ?? "-"
            log.info("My Activity: \(searches.count) searches (\(data.count) bytes from \(host, privacy: .public))")
            MemoryRelief.soon()
            return searches
        } catch {
            log.error("My Activity failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// A session with its own in-memory cookie jar, seeded from the account's cookies, so the
    /// redirects between accounts.google.com and myactivity.google.com carry the right ones
    /// and the page's session cookie is kept for later reads.
    private func session() async -> URLSession {
        if let urlSession { return urlSession }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let jar = configuration.httpCookieStorage ?? HTTPCookieStorage()
        for c in await account.allCookies() where c.domain.hasSuffix("google.com") {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: c.name, .value: c.value, .domain: c.domain, .path: c.path]
            if c.secure { properties[.secure] = "TRUE" }
            if let expires = c.expires { properties[.expires] = expires }
            if let cookie = HTTPCookie(properties: properties) { jar.setCookie(cookie) }
        }
        configuration.httpCookieStorage = jar
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        urlSession = session
        return session
    }

    /// The sign-in handoff form (action and hidden fields), if this page is one.
    nonisolated static func osidForm(in data: Data) -> (action: URL, fields: [String: String])? {
        let html = String(decoding: data, as: UTF8.self)
        guard html.contains("SetOSID"),
              let tag = html.firstMatch(of: /<form[^>]*action="([^"]*SetOSID[^"]*)"[^>]*>/),
              let action = URL(string: unescape(String(tag.1))) else { return nil }
        var fields: [String: String] = [:]
        for input in html.matches(of: /<input[^>]*type="hidden"[^>]*>/) {
            let text = String(input.0)
            guard let name = text.firstMatch(of: /name="([^"]*)"/)?.1,
                  let value = text.firstMatch(of: /value="([^"]*)"/)?.1 else { continue }
            fields[unescape(String(name))] = unescape(String(value))
        }
        return fields.isEmpty ? nil : (action, fields)
    }

    /// Every search on the page, in page order (newest first), without repeats.
    nonisolated static func searches(in data: Data) -> [String] {
        let html = String(decoding: data, as: UTF8.self)
        var seen = Set<String>(), result: [String] = []
        for match in html.matches(of: /youtube\.com\/results\?search_query=([^"&]+)/) {
            let raw = String(match.1).replacingOccurrences(of: "+", with: " ")
            let query = unescape(raw.removingPercentEncoding ?? raw).trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty, seen.insert(query.lowercased()).inserted else { continue }
            result.append(query)
        }
        return result
    }

    private nonisolated static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&#32;", with: " ")
    }
}
