import Foundation
import OSLog

/// YouTube's notification inbox (the bell), its badge, and new-upload alerts.
///
/// Reading the inbox marks it seen on YouTube (its unseen count drops to 0 everywhere, like
/// clicking the bell on youtube.com), while asking for the count changes nothing. So:
/// - alerts off: Velvet only polls the count, and the badge is YouTube's own;
/// - alerts on: when the count is above 0 it reads the inbox to post the new items, and the
///   badge counts items newer than the last time you opened Velvet's inbox.
@Observable
final class InboxModel {
    private(set) var items: [InboxNotification] = []
    private(set) var badge = 0
    private(set) var isLoading = false
    private(set) var error: String?
    var canLoadMore: Bool { continuation != nil }

    @ObservationIgnored private var continuation: String?
    @ObservationIgnored private let client: InnerTubeClient
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let alerts: SystemNotifications
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Velvet", category: "Inbox")

    /// Newest notification you've seen in Velvet's inbox / been alerted about. Notification
    /// ids are increasing numbers (microsecond timestamps), so "newer" is a numeric compare.
    @ObservationIgnored private var lastSeen: UInt64 {
        get { UInt64(UserDefaults.standard.string(forKey: "Inbox.lastSeen") ?? "") ?? 0 }
        set { UserDefaults.standard.set(String(newValue), forKey: "Inbox.lastSeen") }
    }
    @ObservationIgnored private var lastAlerted: UInt64? {
        get { UserDefaults.standard.string(forKey: "Inbox.lastAlerted").flatMap(UInt64.init) }
        set { UserDefaults.standard.set(newValue.map(String.init), forKey: "Inbox.lastAlerted") }
    }

    init(client: InnerTubeClient, preferences: Preferences, alerts: SystemNotifications) {
        self.client = client
        self.prefs = preferences
        self.alerts = alerts
    }

    // MARK: Polling

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5)) // let launch settle first
            while !Task.isCancelled, let self {
                await self.poll()
                try? await Task.sleep(for: .seconds(Double(self.prefs.notificationCheckMinutes) * 60))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        items = []
        badge = 0
    }

    func poll() async {
        do {
            let unseen = NotificationParser.unseenCount(from: try await client.unseenNotificationCount()) ?? 0
            guard prefs.uploadAlerts else { badge = unseen; return }
            // Nothing new on YouTube's side (and we've read the inbox before): nothing to do.
            guard unseen > 0 || lastAlerted == nil else { return }
            let page = NotificationParser.inbox(from: try await client.notificationMenu())
            merge(page)
            updateBadge()
            await alertAboutNew(page.items)
        } catch {
            log.error("Inbox check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Posts an alert for each item newer than the last one alerted about. The first time,
    /// it only notes where the inbox is, so turning alerts on doesn't replay old ones.
    private func alertAboutNew(_ fresh: [InboxNotification]) async {
        let newest = fresh.compactMap { UInt64($0.id) }.max() ?? 0
        guard let last = lastAlerted else { lastAlerted = newest; return }
        let new = fresh.filter { (UInt64($0.id) ?? 0) > last && !$0.isRead }
        lastAlerted = max(last, newest)
        // Oldest first, so they stack in Notification Center in the order they happened.
        for n in new.reversed().prefix(10) { await alerts.post(n) }
        if !new.isEmpty { log.info("Posted \(new.count) upload alert(s)") }
    }

    // MARK: The inbox popover

    /// Opening the inbox: load it fresh and count everything in it as seen.
    func open() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = NotificationParser.inbox(from: try await client.notificationMenu())
            items = page.items
            continuation = page.continuation
            if let newest = items.compactMap({ UInt64($0.id) }).max() {
                lastSeen = max(lastSeen, newest)
                // What you've seen here doesn't need an alert later either.
                if prefs.uploadAlerts { lastAlerted = max(lastAlerted ?? 0, newest) }
            }
            badge = 0
            MemoryRelief.soon()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let token = continuation, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = NotificationParser.inbox(from: try await client.notificationMenu(continuation: token))
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            continuation = page.continuation
        } catch {
            log.error("Inbox page failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks it read here and on YouTube.
    func markRead(_ notification: InboxNotification) {
        guard let i = items.firstIndex(where: { $0.id == notification.id }), !items[i].isRead else { return }
        items[i].isRead = true
        guard let token = notification.readToken else { return }
        Task { try? await client.recordNotificationInteractions([token]) }
    }

    var hasUnread: Bool { items.contains { !$0.isRead } }

    /// Marks every loaded notification read, in one request; put back if YouTube refuses.
    func markAllRead() {
        let unread = items.indices.filter { !items[$0].isRead }
        guard !unread.isEmpty else { return }
        let tokens = unread.compactMap { items[$0].readToken }
        for i in unread { items[i].isRead = true }
        badge = 0
        Task {
            do {
                try await client.recordNotificationInteractions(tokens)
            } catch {
                let ids = Set(unread.map { items[$0].id })
                for i in items.indices where ids.contains(items[i].id) { items[i].isRead = false }
                self.error = "Couldn't mark them as read: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Helpers

    /// Puts a fresh first page on top of what's loaded, keeping older pages.
    private func merge(_ page: InboxPage) {
        let fresh = Set(page.items.map(\.id))
        items = page.items + items.filter { !fresh.contains($0.id) }
        if continuation == nil { continuation = page.continuation }
    }

    private func updateBadge() {
        let seen = lastSeen
        badge = items.filter { (UInt64($0.id) ?? 0) > seen && !$0.isRead }.count
    }
}
