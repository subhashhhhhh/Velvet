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
        // Names are bold rather than links: the About panel always draws links in the
        // system's blue. Settings › About has the links.
        func add(_ s: String, bold: Bool = false, color: NSColor? = nil) {
            var attrs = base
            if bold {
                attrs[.font] = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                attrs[.foregroundColor] = NSColor.labelColor
            }
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
        add("mpv", bold: true)
        add(", ")
        add("yt-dlp", bold: true)
        add(" and ")
        add("MPVKit", bold: true)
        add(".\nSegments from ")
        add("SponsorBlock", bold: true)
        add(", titles and thumbnails from ")
        add("DeArrow", bold: true)
        add(".\nNot affiliated with YouTube or Google.")
        return text
    }
}
