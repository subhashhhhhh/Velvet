import Foundation
import UserNotifications
import OSLog

/// macOS notifications for new uploads: posts them (with the video's thumbnail) and opens the
/// video when one is clicked.
final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the video to open when a notification is clicked.
    var onOpen: ((Video) -> Void)?
    /// Called when the new-version notification is clicked.
    var onOpenUpdate: (() -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Inbox")

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks for permission (macOS shows its prompt only the first time). Returns whether alerts are allowed.
    @discardableResult
    func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    var isAllowed: Bool {
        get async { await center.notificationSettings().authorizationStatus == .authorized }
    }

    func post(_ n: InboxNotification) async {
        let content = UNMutableNotificationContent()
        if let uploader = n.uploader, let title = n.uploadTitle {
            content.title = uploader
            content.body = title
        } else {
            content.title = "YouTube"
            content.body = n.message
        }
        content.sound = .default
        content.threadIdentifier = n.uploader ?? "youtube"
        if let videoId = n.videoId {
            content.userInfo = ["videoId": videoId, "isShort": n.isShort, "title": n.uploadTitle ?? n.message]
        }
        if let attachment = await thumbnailAttachment(for: n) { content.attachments = [attachment] }
        do {
            try await center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
        } catch {
            log.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Announces a new Velvet, only if notifications are already allowed: an update alone
    /// isn't worth macOS's permission prompt (Settings › About shows it too).
    func postUpdate(_ release: AvailableRelease) async {
        guard await isAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "Velvet \(release.version.description) is available"
        content.body = "Click to see what's new and install it."
        content.userInfo = ["update": true]
        try? await center.add(UNNotificationRequest(identifier: "velvet-update-\(release.version.description)", content: content, trigger: nil))
    }

    /// The video's thumbnail as a temporary file (the system moves it into its own store).
    private func thumbnailAttachment(for n: InboxNotification) async -> UNNotificationAttachment? {
        guard let url = n.thumbnail,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "velvet-notification-\(n.id).jpg")
        do {
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "thumbnail", url: file)
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show them even while Velvet is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if info["update"] as? Bool == true {
            await MainActor.run { onOpenUpdate?() }
            return
        }
        guard let videoId = info["videoId"] as? String else { return }
        let isShort = info["isShort"] as? Bool ?? false
        let title = info["title"] as? String ?? ""
        await MainActor.run {
            onOpen?(Video(id: videoId, title: title, kind: isShort ? .short : .video))
        }
    }
}
