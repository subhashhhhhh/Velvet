import SwiftUI

/// The first run: what Velvet is, signing in, and a few choices, while yt-dlp and the
/// JavaScript runtime download (their progress runs along the bottom). Shown once, over the
/// whole window; the views are gone once it's finished.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var step: Step = {
        #if DEBUG
        // `-VelvetWelcomeStep 1` opens on that step (0 welcome, 1 sign in, 2 choices).
        if let n = UserDefaults.standard.object(forKey: "VelvetWelcomeStep") as? Int ?? Int(UserDefaults.standard.string(forKey: "VelvetWelcomeStep") ?? ""),
           let step = Step(rawValue: n) { return step }
        #endif
        return .welcome
    }()

    enum Step: Int, CaseIterable { case welcome, signIn, choices }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome: WelcomeStep { go(to: .signIn) }
                case .signIn: SignInStep { go(to: .choices) }
                case .choices: ChoicesStep { finish() }
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StepDots(current: step)
                .padding(.bottom, 18)
            SetupStrip()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        // Signing in from this step moves on by itself (not the saved session being restored
        // at launch, which goes from unknown, not signed out, to signed in).
        .onChange(of: app.authState) { old, state in
            if old == .signedOut, state == .signedIn, step == .signIn { go(to: .choices) }
        }
    }

    private func go(to next: Step) {
        withAnimation(.smooth(duration: 0.35)) { step = next }
    }

    private func finish() {
        withAnimation(.smooth(duration: 0.3)) { app.settings.hasSeenWelcome = true }
        if app.settings.uploadAlerts { app.uploadAlertsChanged() }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        StepLayout {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            VStack(spacing: 8) {
                Text("Welcome to Velvet")
                    .font(.system(size: 30, weight: .bold))
                Text("YouTube as a Mac app, with a fraction of the memory.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "play.rectangle", title: "Plays in mpv",
                        detail: "Up to 4K and HDR, with Picture in Picture and media keys.")
                Feature(symbol: "forward.end", title: "Skips sponsors, fixes clickbait",
                        detail: "SponsorBlock and DeArrow are built in.")
                Feature(symbol: "person.crop.rectangle.stack", title: "Your YouTube",
                        detail: "Your feed, subscriptions, history and playlists.")
            }
            .padding(.top, 6)
        } actions: {
            Button("Continue", action: next)
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct SignInStep: View {
    @Environment(AppModel.self) private var app
    let next: () -> Void

    var body: some View {
        StepLayout {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("Sign in to YouTube")
                    .font(.system(size: 30, weight: .bold))
                Text("Velvet shows what YouTube shows you.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "house", title: "Your home feed and subscriptions",
                        detail: "Recommendations and new videos from your channels.")
                Feature(symbol: "clock.arrow.circlepath", title: "History, Watch Later and playlists",
                        detail: "The same as on youtube.com and your phone.")
                Feature(symbol: "lock", title: "Private",
                        detail: "You sign in on Google's own page. Velvet keeps the session only on this Mac and sends it only to Google and YouTube.")
            }
            .padding(.top, 6)
        } actions: {
            if app.authState == .signedIn {
                // Already signed in (Velvet was installed before).
                Label("Signed in as \(app.account?.name ?? "your account")", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                Button("Continue", action: next)
                    .buttonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now", action: next)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                Button("Sign In with Google") { app.showingSignIn = true }
                    .buttonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ChoicesStep: View {
    @Environment(AppModel.self) private var app
    let done: () -> Void

    var body: some View {
        @Bindable var settings = app.settings
        StepLayout {
            if app.authState == .signedIn {
                AccountPhoto(size: 64)
                VStack(spacing: 8) {
                    Text(app.account.map { "Hi, \($0.name.split(separator: " ").first.map(String.init) ?? $0.name)" } ?? "You're signed in")
                        .font(.system(size: 30, weight: .bold))
                    Text("A few choices to start with.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    Text("A few choices")
                        .font(.system(size: 30, weight: .bold))
                    Text("You can change them any time in Settings.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ChoiceRow(symbol: "forward.end", title: "Skip sponsors",
                          detail: "SponsorBlock skips sponsor segments that viewers marked.",
                          isOn: $settings.sponsorBlockEnabled)
                Divider().padding(.leading, 44)
                ChoiceRow(symbol: "textformat", title: "Better titles and thumbnails",
                          detail: "DeArrow replaces clickbait with titles and thumbnails from viewers.",
                          isOn: Binding(
                            get: { settings.deArrowTitles || settings.deArrowThumbnails != .off },
                            set: { on in
                                settings.deArrowTitles = on
                                settings.deArrowThumbnails = on ? .random : .off
                            }))
                if app.authState == .signedIn {
                    Divider().padding(.leading, 44)
                    ChoiceRow(symbol: "bell", title: "Notify me about new uploads",
                              detail: "From channels whose bell is on. macOS asks for permission.",
                              isOn: $settings.uploadAlerts)
                }
            }
            .padding(.vertical, 4)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 480)
        } actions: {
            Button("Start Watching", action: done)
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Pieces

/// A step: content centred, its buttons under it.
private struct StepLayout<Content: View, Actions: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 22) {
            content
            HStack(spacing: 12) { actions }
                .padding(.top, 12)
        }
        .frame(maxWidth: 520)
        .padding(32)
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 440)
    }
}

private struct ChoiceRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct StepDots: View {
    let current: WelcomeView.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WelcomeView.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(.primary.opacity(step == current ? 0.8 : 0.2))
                    .frame(width: step == current ? 18 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.3), value: current)
    }
}

/// Along the bottom of the welcome flow: yt-dlp and the runtime downloading.
private struct SetupStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let runtime = app.settings.jsRuntime
        HStack(spacing: 20) {
            if app.tools.isReady(runtime: runtime) {
                Label("Playback is ready", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setting up playback").font(.callout.weight(.semibold))
                    Text("Velvet downloads yt-dlp and \(Tool(runtime).displayName), which find each video's streams.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ToolSetupRows()
                if app.tools.setupFailure(runtime: runtime) != nil {
                    Button("Try Again") { app.tools.retrySetup(runtime: runtime) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: app.tools.isReady(runtime: runtime) ? .center : .leading)
        .padding(.horizontal, 24)
        .frame(height: 76)
        .background(.primary.opacity(0.04))
        .overlay(alignment: .top) { Divider() }
        .animation(.smooth(duration: 0.3), value: app.tools.isReady(runtime: runtime))
    }
}

/// After the welcome flow, while yt-dlp and the runtime are still downloading.
struct SetupPill: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let runtime = app.settings.jsRuntime
        HStack(spacing: 10) {
            if app.tools.setupFailure(runtime: runtime) != nil {
                Image(systemName: "exclamationmark.triangle")
                Text("Playback setup failed")
                Button("Try Again") { app.tools.retrySetup(runtime: runtime) }
            } else {
                ProgressView(value: app.tools.setupFraction(runtime: runtime))
                    .frame(width: 80)
                Text("Setting up playback · \(Int(app.tools.setupFraction(runtime: runtime) * 100)) %")
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}
