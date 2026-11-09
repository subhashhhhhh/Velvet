import AppKit

/// The standard About panel, with a tagline, the downloaded tool versions and credits.
/// Built when the menu item is chosen, so it costs nothing until then.
enum AboutPanel {
    static func show(tools: ToolManager) {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits(tools: tools)])
        NSApp.activate()
    }

    private static func credits(tools: ToolManager) -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        let text = NSMutableAttributedString()
        func add(_ s: String, link: String? = nil, color: NSColor? = nil) {
            var attrs = base
            if let link { attrs[.link] = URL(string: link) }
            if let color { attrs[.foregroundColor] = color }
            text.append(NSAttributedString(string: s, attributes: attrs))
        }

        add("A native YouTube client for macOS.\n", color: .labelColor)

        // Versions of the tools ToolManager downloaded (they update on their own, so they
        // are useful to know when a stream stops resolving).
        let installed = Tool.allCases.compactMap { tool -> String? in
            if case .installed(let version) = tools.status[tool] { return "\(tool.displayName) \(version)" }
            return nil
        }
        if !installed.isEmpty { add(installed.joined(separator: " · ") + "\n") }

        add("Built with ")
        add("mpv", link: "https://mpv.io")
        add(", ")
        add("yt-dlp", link: "https://github.com/yt-dlp/yt-dlp")
        add(" and ")
        add("MPVKit", link: "https://github.com/mpvkit/MPVKit")
        add(".\nSegments from ")
        add("SponsorBlock", link: "https://sponsor.ajay.app")
        add(", titles and thumbnails from ")
        add("DeArrow", link: "https://dearrow.ajay.app")
        add(".\nNot affiliated with YouTube or Google.")
        return text
    }
}
