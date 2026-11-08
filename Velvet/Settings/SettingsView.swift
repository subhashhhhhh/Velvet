import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane() }
            Tab("Feed", systemImage: "square.grid.2x2") { FeedPane() }
            Tab("Playback", systemImage: "play.rectangle") { PlaybackPane() }
            Tab("SponsorBlock", systemImage: "forward.end") { SponsorBlockPane() }
            Tab("DeArrow", systemImage: "arrow.uturn.down.circle") { DeArrowPane() }
            Tab("Account", systemImage: "person.crop.circle") { AccountPane() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedPane() }
        }
        .frame(width: 560)
        .scenePadding(.minimum)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Picker("Open at launch", selection: $settings.startPage) {
                ForEach(Destination.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Feed

private struct FeedPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Layout") {
                Picker("Card size", selection: $settings.cardSize) {
                    ForEach(CardSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Shorts") {
                Toggle("Show Shorts shelf in feeds", isOn: $settings.showShortsShelf)
                Stepper(value: $settings.shortsAfterRows, in: 0...10) {
                    LabeledContent("Place shelf after", value: settings.shortsAfterRows == 0
                                   ? "Top of feed" : "\(settings.shortsAfterRows) rows")
                }
                .disabled(!settings.showShortsShelf)
            }
            Section {
                Toggle("Hide videos I've already watched", isOn: $settings.hideWatched)
                Toggle("Hide members-only videos", isOn: $settings.hideMembersOnly)
            } footer: {
                Text("Hides videos YouTube reports as mostly watched (90% or more).")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Playback

private struct PlaybackPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Quality") {
                Picker("Preferred quality", selection: $settings.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                }
                Picker("Preferred codec", selection: $settings.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }
                Text(settings.codec.detail).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Start playing when a video opens", isOn: $settings.autoplay)
                Toggle("Picture in Picture when switching away", isOn: $settings.autoPictureInPicture)
                    .disabled(!PictureInPicture.isAvailable)
                Toggle("Picture in Picture when scrolling past the player", isOn: $settings.pipOnScroll)
                    .disabled(!PictureInPicture.isAvailable)
                Toggle("Show captions automatically", isOn: $settings.autoCaptions)
                Picker("Default speed", selection: $settings.defaultSpeed) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) {
                        Text($0 == 1 ? "Normal" : "\($0.formatted())×").tag($0)
                    }
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text("When the Velvet window is hidden while a video plays — another Space, minimized, or covered — the video continues in a floating Picture in Picture window, and returns when you come back.")
            }
            Section {
                Toggle("Hardware decoding", isOn: $settings.hardwareDecoding)
                Picker("Maximum buffer", selection: $settings.bufferMB) {
                    ForEach([50, 100, 150, 300, 500], id: \.self) { Text("\($0) MB").tag($0) }
                }
                Toggle("Prepare videos when hovering", isOn: $settings.prefetchOnHover)
            } header: {
                Text("Performance")
            } footer: {
                Text("Velvet buffers about 30 seconds ahead, up to this limit. Hover preparation looks up stream links in advance so playback starts faster.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - SponsorBlock

private struct SponsorBlockPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Enable SponsorBlock", isOn: $settings.sponsorBlockEnabled)
                Toggle("Show a notice when a segment is skipped", isOn: $settings.showSkipNotice)
                    .disabled(!settings.sponsorBlockEnabled)
            } footer: {
                Text("Crowd-sourced segments from sponsor.ajay.app. Video IDs are looked up by hash prefix, so the server never sees which video you watch.")
            }
            Section("Categories") {
                ForEach(SponsorCategory.allCases) { category in
                    Picker(category.label, selection: Binding(
                        get: { settings.sponsorAction(for: category) },
                        set: { settings.sponsorActions[category] = $0 }
                    )) {
                        ForEach(SponsorAction.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            .disabled(!settings.sponsorBlockEnabled)
            Section("Server") {
                TextField("API server", text: $settings.sponsorBlockServer)
                    .textFieldStyle(.roundedBorder)
                if settings.sponsorBlockServer != Preferences.defaultSponsorServer {
                    Button("Use Default Server") { settings.sponsorBlockServer = Preferences.defaultSponsorServer }
                }
            }
            .disabled(!settings.sponsorBlockEnabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: - DeArrow

private struct DeArrowPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Replace clickbait titles", isOn: $settings.deArrowTitles)
                Picker("Thumbnails", selection: $settings.deArrowThumbnails) {
                    ForEach(DeArrowThumbnailMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show originals while hovering", isOn: $settings.deArrowOriginalOnHover)
                    .disabled(!settings.deArrowEnabled)
            } footer: {
                Text("Community-submitted titles and thumbnails from DeArrow. Lookups use a 4-character hash prefix, so the server never learns which videos you're looking at. A random frame is used when nobody has picked a thumbnail yet.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Account

private struct AccountPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            switch app.authState {
            case .signedIn:
                Section {
                    HStack(spacing: 12) {
                        RemoteImage(url: app.account?.photo)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(app.account?.name ?? "Signed In").font(.headline)
                            if let handle = app.account?.handle {
                                Text(handle).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                    }
                } footer: {
                    Text("Your session is stored only on this Mac, readable by your user account alone.")
                }
            case .signedOut, .unknown:
                Section {
                    LabeledContent("Google Account") {
                        Button("Sign In…") { app.showingSignIn = true }
                    }
                } footer: {
                    Text("Signing in enables your recommendations, history, Watch Later and playlists.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct ToolRow: View {
    let tool: Tool
    @Environment(AppModel.self) private var app

    var body: some View {
        LabeledContent(tool.displayName) {
            HStack(spacing: 8) {
                switch app.tools.status[tool] ?? .notInstalled {
                case .notInstalled:
                    Text("Not installed").foregroundStyle(.secondary)
                    Button("Install") { Task { try? await app.tools.install(tool) } }
                case .working(let step):
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(.secondary)
                case .installed(let version):
                    Text(version).monospacedDigit().foregroundStyle(.secondary)
                    Button("Reinstall") { Task { try? await app.tools.install(tool) } }
                case .failed(let message):
                    Text(message).foregroundStyle(.red).lineLimit(2)
                    Button("Retry") { Task { try? await app.tools.install(tool) } }
                }
            }
        }
    }
}

private struct AdvancedPane: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingReset = false
    @State private var cacheCleared = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("JavaScript runtime", selection: $settings.jsRuntime) {
                    ForEach(JSRuntime.allCases) { Text($0.label).tag($0) }
                }
                Text(settings.jsRuntime.detail).font(.caption).foregroundStyle(.secondary)
                Toggle("Keep yt-dlp and the runtime up to date automatically", isOn: $settings.autoUpdateTools)
                ToolRow(tool: .ytdlp)
                ToolRow(tool: Tool(settings.jsRuntime))
                LabeledContent("Updates") {
                    HStack {
                        if let last = app.tools.lastUpdateCheck {
                            Text("Checked \(last, format: .relative(presentation: .named))")
                                .foregroundStyle(.secondary)
                        }
                        Button("Check Now") { Task { await app.tools.checkForUpdates(force: true) } }
                    }
                }
            } header: {
                Text("Stream Extraction")
            } footer: {
                Text("yt-dlp finds stream links; the runtime solves YouTube's player challenges. Both run only briefly when a video opens.")
            }
            Section("Storage") {
                LabeledContent("Image cache") {
                    Button(cacheCleared ? "Cleared" : "Clear") {
                        Task {
                            await ImagePipeline.shared.clearAll()
                            cacheCleared = true
                        }
                    }
                    .disabled(cacheCleared)
                }
            }
            Section {
                LabeledContent("Preferences") {
                    Button("Reset All Settings…", role: .destructive) { confirmingReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { settings.resetAll() }
        } message: {
            Text("Your account stays signed in.")
        }
    }
}
