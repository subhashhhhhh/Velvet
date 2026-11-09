import AppKit
import SwiftUI

/// Settings › About: who makes Velvet, where to report problems, and its own updates.
struct AboutPane: View {
    @Environment(AppModel.self) private var app

    private static let developerURL = URL(string: "https://github.com/subhashhhhhh")!

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Velvet")
                            .font(.system(size: 22, weight: .bold))
                        Text(versionText)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("A native YouTube client for macOS.")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text("Made by")
                            TextLink("Subhash", url: Self.developerURL)
                        }
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $settings.checkAppUpdates)
                UpdateStatusRow(updates: app.updates)
            }

            Section {
                LinkRow(title: "Source code", detail: "GitHub", url: ReleaseFeed.repositoryURL)
                LinkRow(title: "Report a problem or suggest a feature", detail: "GitHub Issues", url: ReleaseFeed.newIssue)
                LinkRow(title: "Release notes", detail: "All versions", url: ReleaseFeed.releasesPage)
            } header: {
                Text("Links")
            }

            Section {
                Text(credits)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("Velvet is free and open source under the MIT License. It is not affiliated with YouTube or Google.")
            }
        }
        .formStyle(.grouped)
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(version) (\(build))"
    }

    private var credits: AttributedString {
        let markdown = "Playback by [mpv](https://mpv.io) through [MPVKit](https://github.com/mpvkit/MPVKit). Streams found by [yt-dlp](https://github.com/yt-dlp/yt-dlp) with [Deno](https://deno.com). Skippable segments from [SponsorBlock](https://sponsor.ajay.app), better titles and thumbnails from [DeArrow](https://dearrow.ajay.app)."
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}

private struct LinkRow: View {
    let title: String
    let detail: String
    let url: URL

    var body: some View {
        LabeledContent(title) {
            TextLink(detail, url: url, arrow: true)
        }
    }
}

/// A link in the text colour, underlined on hover. SwiftUI's `Link` is always the system's
/// blue link colour, whatever the tint.
private struct TextLink: View {
    let title: String
    let url: URL
    var arrow = false
    @State private var hovering = false

    init(_ title: String, url: URL, arrow: Bool = false) {
        self.title = title
        self.url = url
        self.arrow = arrow
    }

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                Text(title).underline(hovering)
                if arrow {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .help(url.absoluteString)
    }
}

private struct UpdateStatusRow: View {
    let updates: UpdateController

    var body: some View {
        switch updates.state {
        case .idle, .upToDate:
            LabeledContent {
                Button("Check Now") { updates.checkNow() }
            } label: {
                Text(updates.state == .upToDate ? "Velvet is up to date" : "Software update")
                if let last = updates.lastChecked {
                    Text("Checked \(last, format: .relative(presentation: .named))")
                }
            }
        case .checking:
            LabeledContent("Checking for updates…") {
                ProgressView().controlSize(.small)
            }
        case .available(let release):
            VStack(alignment: .leading, spacing: 8) {
                Text("Velvet \(release.version.description) is available")
                    .font(.headline)
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(notes(release.notes))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                }
                HStack {
                    Button("Release Notes") { NSWorkspace.shared.open(release.pageURL) }
                    Spacer()
                    if updates.canInstall {
                        Button("Install and Relaunch") { updates.install() }
                            .buttonStyle(.prominent)
                    } else {
                        // A local build can't verify a download; send it to the release page.
                        Button("Download") { NSWorkspace.shared.open(release.pageURL) }
                            .buttonStyle(.prominent)
                    }
                }
            }
            .padding(.vertical, 4)
        case .installing(let release, let phase):
            VStack(alignment: .leading, spacing: 6) {
                Text("Installing Velvet \(release.version.description)")
                    .font(.headline)
                if let fraction = phase.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(phase.message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if case .downloading = phase {
                        Button("Cancel") { updates.cancelInstall() }
                    }
                }
            }
            .padding(.vertical, 4)
        case .failed(let message):
            LabeledContent {
                Button("Try Again") { updates.checkNow() }
            } label: {
                Text("Couldn't update")
                Text(message)
            }
        }
    }

    private func notes(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
