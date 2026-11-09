import AppKit
import OSLog

private let log = Logger(subsystem: "com.subhash.Velvet", category: "Links")

/// A YouTube link found on the clipboard, offered in a banner.
struct ClipboardOffer: Equatable {
    let link: YouTubeLink

    var message: String {
        switch link {
        case .video: "Open the copied video?"
        case .short: "Open the copied Short?"
        case .playlist: "Open the copied playlist?"
        case .channel, .channelURL: "Open the copied channel?"
        }
    }
}

extension AppModel {
    /// URLs handed to Velvet by macOS: Open With, `open -a Velvet <url>`, `velvet://` links.
    func handleOpenedURLs(_ urls: [URL]) {
        for url in urls {
            guard let link = YouTubeLink(url) else {
                log.info("Not a YouTube link: \(url.absoluteString, privacy: .private)")
                continue
            }
            open(link)
        }
    }

    func open(_ link: YouTubeLink) {
        // Before the session is restored, a video would open signed out; during the welcome,
        // it would play behind it.
        guard linksReady, settings.hasSeenWelcome else {
            pendingLinks.append(link)
            return
        }
        clipboardOffer = nil
        log.info("Opening link: \(String(describing: link), privacy: .public)")
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        switch link {
        case .video(let id, let start):
            open(Video(id: id, title: ""), at: start)
        case .short(let id):
            open(Video(id: id, title: "", kind: .short))
        case .playlist(let id):
            if authState == .signedIn {
                open(PlaylistSummary(id: id, title: "Playlist"))
            } else {
                showToast("Sign in to open playlists")
            }
        case .channel(let id):
            openChannel(id)
        case .channelURL(let url):
            Task {
                guard let id = await resolveChannel(url) else {
                    showToast("Velvet could not find this channel")
                    return
                }
                openChannel(id)
            }
        }
    }

    func openPendingLinks() {
        guard linksReady, settings.hasSeenWelcome, !pendingLinks.isEmpty else { return }
        let links = pendingLinks
        pendingLinks = []
        // Only the last one: several links at once would replace each other anyway.
        if let last = links.last { open(last) }
    }

    /// `/@name` and the older `/c/` and `/user/` addresses, to a channel ID.
    private func resolveChannel(_ url: URL) async -> String? {
        guard let response = try? await client.post("navigation/resolve_url", ["url": .string(url.absoluteString)])
        else { return nil }
        return response.all("browseId").compactMap(\.string).first { $0.hasPrefix("UC") }
    }

    // MARK: - Clipboard

    /// Velvet became active: if a YouTube link was copied since the last check, offer to open it.
    func checkClipboardForLink() {
        let pasteboard = NSPasteboard.general
        guard settings.offerCopiedLinks, linksReady, settings.hasSeenWelcome,
              pasteboard.changeCount != checkedPasteboardChange else { return }
        checkedPasteboardChange = pasteboard.changeCount

        if #available(macOS 15.4, *) {
            log.debug("Clipboard changed; access behavior \(pasteboard.accessBehavior.rawValue)")
            if pasteboard.accessBehavior == .alwaysDeny { return }
            // Look first without reading: macOS can tell the user each time an app reads the
            // clipboard, so Velvet reads it only when it holds a web address.
            Task {
                // NSPasteboard isn't Sendable; the general pasteboard is safe to ask from here.
                nonisolated(unsafe) let general = NSPasteboard.general
                guard let found = try? await general.detectedPatterns(for: [\.probableWebURL]),
                      found.contains(\NSPasteboard.DetectedValues.probableWebURL) else { return }
                readClipboardLink()
            }
        } else {
            readClipboardLink()
        }
    }

    private func readClipboardLink() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let link = YouTubeLink(text: text) else { return }
        // Not the video that is already open.
        if let id = link.videoID, id == watching?.video.id || id == shortsOverlay?.sequence.current?.id { return }
        log.info("Offering the copied link: \(String(describing: link), privacy: .public)")
        clipboardOffer = ClipboardOffer(link: link)
        clipboardOfferTask?.cancel()
        clipboardOfferTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            clipboardOffer = nil
        }
    }

    func acceptClipboardOffer() {
        guard let offer = clipboardOffer else { return }
        clipboardOffer = nil
        open(offer.link)
    }

    func dismissClipboardOffer() {
        clipboardOffer = nil
        clipboardOfferTask?.cancel()
    }
}
