import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, feed, playback, notifications, sponsorBlock, deArrow, account, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .feed: "Feed"
        case .playback: "Playback"
        case .notifications: "Notifications"
        case .sponsorBlock: "SponsorBlock"
        case .deArrow: "DeArrow"
        case .account: "Account"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .feed: "square.grid.2x2"
        case .playback: "play.rectangle"
        case .notifications: "bell"
        case .sponsorBlock: "forward.end"
        case .deArrow: "textformat"
        case .account: "person.crop.circle"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

/// The Settings window, laid out like the main window: a floating sidebar of categories
/// (window buttons inside it) and the selected category's settings, its title in the bar.
struct SettingsView: View {
    @State private var pane: SettingsPane = {
        #if DEBUG
        // `-VelvetSettingsPane playback` opens on that pane.
        if let raw = UserDefaults.standard.string(forKey: "VelvetSettingsPane"), let pane = SettingsPane(rawValue: raw) { return pane }
        #endif
        return .general
    }()

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $pane)
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(height: TopBar.height)
                    .padding(.horizontal, 28)
                content
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 800, height: 580)
        // As in the main window: an empty toolbar keeps the window buttons centred in the
        // 52pt bar, and Velvet draws everything under it.
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) }
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(pane.title)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general: GeneralPane()
        case .feed: FeedPane()
        case .playback: PlaybackPane()
        case .notifications: NotificationsPane()
        case .sponsorBlock: SponsorBlockPane()
        case .deArrow: DeArrowPane()
        case .account: AccountPane()
        case .advanced: AdvancedPane()
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPane
    @Environment(AppModel.self) private var app
    @Namespace private var highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: SidebarMetrics.windowButtons(fullscreen: false))
            if app.authState == .signedIn {
                Button { selection = .account } label: {
                    HStack(spacing: 10) {
                        AccountPhoto(size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.account?.name ?? "Signed In")
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text("Google Account")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(SettingsPane.allCases) { pane in
                let selected = pane == selection
                SidebarRow(title: pane.title, isSelected: selected, selection: highlight, action: { selection = pane }) {
                    Image(systemName: pane.symbol)
                        .symbolVariant(selected ? .fill : .none)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(width: 22)
                }
            }
            Spacer(minLength: 0)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Velvet \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 10)
        .animation(.smooth(duration: 0.28), value: selection)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(SidebarPanel())
        .padding([.leading, .vertical], SidebarMetrics.inset)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Picker("Open at launch", selection: $settings.startPage) {
                ForEach(Destination.allCases.filter { $0 != .queue }) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Toggle("Show the sidebar as icons only", isOn: Binding(
                get: { app.isSidebarCollapsed },
                set: { if $0 != app.isSidebarCollapsed { app.toggleSidebar() } }
            ))
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
            Section {
                Stepper(value: $settings.videosPerRow, in: 1...8) {
                    LabeledContent("Videos per row with the sidebar", value: "\(settings.videosPerRow)")
                }
                Stepper(value: $settings.videosPerRowSidebarHidden, in: 1...8) {
                    LabeledContent("Videos per row without the sidebar", value: "\(settings.videosPerRowSidebarHidden)")
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("A narrow window shows fewer, so cards stay readable.")
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
                Toggle("Hide YouTube featured promotions and ads", isOn: $settings.hidePromotions)
                    .onChange(of: settings.hidePromotions) { Task { await app.homeFeed?.reload() } }
            } footer: {
                Text("Watched: videos YouTube reports as mostly watched (90% or more). Promotions: shelves YouTube features for campaigns such as film launches, which aren't based on what you watch.")
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
                Picker("Picture in Picture style", selection: $settings.pipStyle) {
                    ForEach(PiPStyle.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!PictureInPicture.isSystemAvailable)
                Toggle("Picture in Picture when switching away", isOn: $settings.autoPictureInPicture)
                    .disabled(!PictureInPicture.isAvailable)
                Toggle("Picture in Picture when scrolling past the player", isOn: $settings.pipOnScroll)
                    .disabled(!PictureInPicture.isAvailable)
                Toggle("Keep playing in Picture in Picture when leaving the video", isOn: $settings.pipOnNavigate)
                    .disabled(!PictureInPicture.isAvailable)
                Toggle("Show captions automatically", isOn: $settings.autoCaptions)
                Toggle("Play the next video in the queue when one ends", isOn: $settings.queueAutoAdvance)
                Toggle("Theater mode (T)", isOn: $settings.theaterMode)
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

private struct NotificationsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            if app.authState == .signedIn {
                NotificationsSection()
            } else {
                Section {
                    LabeledContent("Notifications come from your YouTube account.") {
                        Button("Sign In…") { app.showingSignIn = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationsSection: View {
    @Environment(AppModel.self) private var app
    @State private var allowed = true

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Toggle("Notify me about new uploads", isOn: $settings.uploadAlerts)
                .onChange(of: settings.uploadAlerts) { app.uploadAlertsChanged(); Task { allowed = await app.alerts.isAllowed } }
            Picker("Check every", selection: $settings.notificationCheckMinutes) {
                ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            if settings.uploadAlerts && !allowed {
                LabeledContent("Notifications are off for Velvet in macOS.") {
                    Button("Open Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
        } footer: {
            Text("Alerts come from your YouTube notifications: uploads from channels whose bell is on (All or Personalized), replies and mentions. Velvet checks while it's running, even with its window closed. Reading them marks them seen on YouTube, as opening the bell there does.")
        }
        .task { allowed = await app.alerts.isAllowed }
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
