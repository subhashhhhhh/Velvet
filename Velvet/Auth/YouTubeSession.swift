import Foundation
import CryptoKit
import OSLog
import Security

/// A cookie in a Codable, Sendable form we fully control.
nonisolated struct StoredCookie: Codable, Hashable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var secure: Bool
    var httpOnly: Bool

    init(_ c: HTTPCookie) {
        name = c.name; value = c.value; domain = c.domain; path = c.path
        expires = c.expiresDate; secure = c.isSecure; httpOnly = c.isHTTPOnly
    }

    var isExpired: Bool { expires.map { $0 < .now } ?? false }

    /// RFC 6265 domain matching: ".youtube.com" / "youtube.com" match "www.youtube.com".
    func matches(host: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == d || host.hasSuffix("." + d)
    }

    /// Identity used to replace a cookie when Google rotates it.
    var key: String { "\(name)|\(domain.hasPrefix(".") ? String(domain.dropFirst()) : domain)|\(path)" }
}

/// The signed-in YouTube session: cookies plus the SAPISIDHASH auth header youtube.com sends.
actor YouTubeSession: InnerTubeAuthProvider {
    private var cookies: [String: StoredCookie]
    private let store: SessionStore
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Session")
    private var saveTask: Task<Void, Never>?

    init(cookies: [StoredCookie], store: SessionStore = .shared) {
        self.cookies = Dictionary(cookies.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        self.store = store
    }

    /// Restores the saved session, if any.
    static func restore(store: SessionStore = .shared) -> YouTubeSession? {
        guard let saved = store.load(), saved.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }) else {
            return nil
        }
        return YouTubeSession(cookies: saved, store: store)
    }

    func save() { store.save(Array(cookies.values)) }

    // MARK: InnerTubeAuthProvider

    func headers(origin: String) async -> [String: String] {
        let host = URL(string: origin)?.host() ?? "www.youtube.com"
        let jar = cookies(for: host)
        var headers = ["X-Goog-AuthUser": "0"]
        if !jar.isEmpty {
            headers["Cookie"] = jar.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        if let auth = Self.authorization(cookies: jar, origin: origin) {
            headers["Authorization"] = auth
        }
        return headers
    }

    /// Absorbs rotated cookies (Google refreshes `__Secure-*PSIDTS` and friends periodically).
    func absorb(responseHeaders: [String: String], url: URL) async {
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url)
        guard !fresh.isEmpty else { return }
        var changed = false
        for c in fresh.map(StoredCookie.init) {
            if c.isExpired {
                changed = cookies.removeValue(forKey: c.key) != nil || changed
            } else if cookies[c.key]?.value != c.value {
                cookies[c.key] = c
                changed = true
            }
        }
        guard changed else { return }
        log.debug("Absorbed \(fresh.count) rotated cookie(s)")
        // Coalesce bursts of responses into one disk write.
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    // MARK: Cookie access

    func cookies(for host: String) -> [StoredCookie] {
        cookies.values
            .filter { !$0.isExpired && $0.matches(host: host) }
            .sorted { $0.name < $1.name }
    }

    func allCookies() -> [StoredCookie] { Array(cookies.values) }

    /// Netscape cookies.txt for yt-dlp (`--cookies`).
    func netscapeCookieFile() -> String {
        var lines = ["# Netscape HTTP Cookie File"]
        for c in cookies.values where !c.isExpired && (c.matches(host: "www.youtube.com") || c.matches(host: "accounts.google.com")) {
            let domain = c.domain
            let includeSub = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let expiry = c.expires.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            lines.append([domain, includeSub, c.path, c.secure ? "TRUE" : "FALSE", expiry, c.name, c.value].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: SAPISIDHASH

    /// Builds youtube.com's Authorization header:
    /// `SAPISIDHASH <ts>_<sha1("<ts> <SAPISID> <origin>")>` plus the 1P/3P variants.
    nonisolated static func authorization(cookies: [StoredCookie], origin: String, now: Date = .now) -> String? {
        func value(_ name: String) -> String? { cookies.first { $0.name == name }?.value }
        let ts = String(Int(now.timeIntervalSince1970))
        func hash(_ secret: String) -> String {
            let digest = Insecure.SHA1.hash(data: Data("\(ts) \(secret) \(origin)".utf8))
            return "\(ts)_" + digest.map { String(format: "%02x", $0) }.joined()
        }
        var parts: [String] = []
        if let s = value("SAPISID") ?? value("__Secure-3PAPISID") { parts.append("SAPISIDHASH \(hash(s))") }
        if let s = value("__Secure-1PAPISID") { parts.append("SAPISID1PHASH \(hash(s))") }
        if let s = value("__Secure-3PAPISID") { parts.append("SAPISID3PHASH \(hash(s))") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Keeps the session cookies in the login keychain, as one generic-password item. The keychain
/// encrypts it, and its access list admits Velvet as signed with the release certificate:
/// another app (or a build signed otherwise) gets macOS's permission prompt instead.
/// Until 1.0 the cookies were a 0600 JSON file in Application Support; the first load moves
/// that file in and deletes it.
nonisolated struct SessionStore: Sendable {
    static let shared = SessionStore()

    private static let service = "com.subhash.Velvet.session"
    private static let account = "YouTube"

    /// Where older versions kept the session.
    private let legacyFile: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "com.subhash.Velvet", directoryHint: .isDirectory)
        .appending(path: "session.json")

    private var log: Logger { Logger(subsystem: "com.subhash.Velvet", category: "Session") }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func load() -> [StoredCookie]? {
        // Only older versions write the file, so when it's there it's the newest session:
        // move it into the keychain.
        if let data = try? Data(contentsOf: legacyFile),
           let cookies = try? JSONDecoder().decode([StoredCookie].self, from: data) {
            if write(data) {
                try? FileManager.default.removeItem(at: legacyFile)
                log.info("Moved the session from session.json into the keychain")
            }
            return cookies
        }
        guard let data = read() else { return nil }
        return try? JSONDecoder().decode([StoredCookie].self, from: data)
    }

    func save(_ cookies: [StoredCookie]) {
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        _ = write(data)
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: legacyFile)
    }

    private func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("Keychain read failed: \(status)")
        }
        return status == errSecSuccess ? result as? Data : nil
    }

    private func write(_ data: Data) -> Bool {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Velvet: YouTube sign-in"
            add[kSecAttrDescription as String] = "Session cookies"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { log.error("Keychain write failed: \(status)") }
        return status == errSecSuccess
    }
}
