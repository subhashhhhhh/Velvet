import SwiftUI

/// The account picture in the top bar. Opens a panel with the account, the settings changed
/// most often, Settings and Sign Out. Signed out, it's a Sign In button.
struct AccountButton: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        @Bindable var app = app
        let showing = app.showingAccount
        switch app.authState {
        case .unknown:
            EmptyView()
        case .signedOut:
            HStack(spacing: 4) {
                ChromeButton("Settings", symbol: "gearshape") { app.showingAccount.toggle() }
                    .popover(isPresented: $app.showingAccount, arrowEdge: .bottom) { AccountPanel { app.showingAccount = false } }
                Button("Sign In") { app.showingSignIn = true }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        case .signedIn:
            Button { app.showingAccount.toggle() } label: {
                AccountPhoto(size: 28)
                    .overlay(Circle().strokeBorder(.primary.opacity(hovering || showing ? 0.35 : 0.1), lineWidth: hovering || showing ? 2 : 1))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(app.account?.name ?? "Account")
            .popover(isPresented: $app.showingAccount, arrowEdge: .bottom) { AccountPanel { app.showingAccount = false } }
        }
    }
}

struct AccountPhoto: View {
    let size: CGFloat
    @Environment(AppModel.self) private var app

    var body: some View {
        RemoteImage(url: app.account?.photo)
            .frame(width: size, height: size)
            .background(Circle().fill(.quaternary))
            .clipShape(Circle())
    }
}

private struct AccountPanel: View {
    var dismiss: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 0) {
            if app.authState == .signedIn {
                HStack(spacing: 12) {
                    AccountPhoto(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.account?.name ?? "Signed In")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if let handle = app.account?.handle {
                            Text(handle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(14)
                Divider().padding(.horizontal, 10)
            }

            sectionHeader("Quick Settings")
            VStack(spacing: 0) {
                QuickToggle("Skip sponsors", detail: "SponsorBlock", symbol: "forward.end", isOn: $settings.sponsorBlockEnabled)
                QuickToggle("Better titles", detail: "DeArrow", symbol: "textformat", isOn: $settings.deArrowTitles)
                QuickToggle("Hide promotions", symbol: "megaphone", isOn: $settings.hidePromotions)
                    .onChange(of: settings.hidePromotions) { Task { await app.homeFeed?.reload() } }
                QuickToggle("Hide watched videos", symbol: "eye.slash", isOn: $settings.hideWatched)
                QuickToggle("Shorts in feeds", symbol: "play.rectangle.on.rectangle", isOn: $settings.showShortsShelf)
                QuickToggle("Captions", symbol: "captions.bubble", isOn: $settings.autoCaptions)
                if app.authState == .signedIn {
                    QuickToggle("Upload alerts", symbol: "bell.badge", isOn: $settings.uploadAlerts)
                        .onChange(of: settings.uploadAlerts) { app.uploadAlertsChanged() }
                }
                QuickRow("Quality", symbol: "sparkles.tv") {
                    Picker("Quality", selection: $settings.quality) {
                        ForEach(VideoQuality.allCases) { Text($0 == .auto ? "Best" : $0.label).tag($0) }
                    }
                }
                QuickRow("Speed", symbol: "gauge.with.dots.needle.67percent") {
                    Picker("Speed", selection: $settings.defaultSpeed) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) {
                            Text($0 == 1 ? "Normal" : "\($0.formatted())×").tag($0)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)

            Divider().padding(.horizontal, 10).padding(.top, 6)
            VStack(spacing: 0) {
                SettingsLink {
                    PanelRowLabel(title: "Settings…", symbol: "gearshape", trailing: "⌘,")
                }
                .buttonStyle(PanelRowStyle())
                .simultaneousGesture(TapGesture().onEnded { dismiss() })
                if app.authState == .signedIn {
                    Button {
                        dismiss()
                        Task { await app.signOut() }
                    } label: {
                        PanelRowLabel(title: "Sign Out", symbol: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(PanelRowStyle())
                }
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

/// A row with an icon, a title and a control on the right.
private struct QuickRow<Control: View>: View {
    let title: String
    var detail: String?
    let symbol: String
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, symbol: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title).font(.system(size: 13))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            control
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }
}

private struct QuickToggle: View {
    let title: String
    var detail: String?
    let symbol: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, symbol: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self._isOn = isOn
    }

    var body: some View {
        QuickRow(title, detail: detail, symbol: symbol) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        // The whole row flips the switch, not just the switch.
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

private struct PanelRowLabel: View {
    let title: String
    let symbol: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20)
            Text(title).font(.system(size: 13))
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A menu-like row: highlights on hover.
private struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledRow(configuration: configuration)
    }

    private struct StyledRow: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
