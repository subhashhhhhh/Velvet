import SwiftUI

// MARK: - What pages put in the top bar

/// A button a page puts in the top bar (Refresh, Play…).
struct TopBarAction: Identifiable {
    let id: String
    let symbol: String
    var shortcut: KeyEquivalent?
    var disabled = false
    let perform: () -> Void
}

/// What the page on screen wants in the top bar. Pages nest, and the innermost one wins: an
/// outer page only fills what its child left empty. Back normally steps through the app's
/// history (AppModel.goBack); a page sets `back` only for a step that isn't in it (a playlist
/// opened inside a channel page).
struct TopBarContent {
    var title: String?
    var back: (() -> Void)?
    var actions: [TopBarAction]?
}

struct TopBarKey: PreferenceKey {
    static var defaultValue: TopBarContent { TopBarContent() }
    static func reduce(value: inout TopBarContent, nextValue: () -> TopBarContent) {
        let next = nextValue()
        value.title = value.title ?? next.title
        value.back = value.back ?? next.back
        value.actions = value.actions ?? next.actions
    }
}

extension View {
    /// A title for the top bar, for pages the sidebar doesn't already name.
    func topBarTitle(_ title: String?) -> some View {
        transformPreference(TopBarKey.self) { if $0.title == nil { $0.title = title } }
    }

    /// Shows the top bar's Back button (⌘[), which runs `action`.
    func topBarBack(_ action: @escaping () -> Void) -> some View {
        transformPreference(TopBarKey.self) { if $0.back == nil { $0.back = action } }
    }

    func topBarActions(_ actions: [TopBarAction]) -> some View {
        transformPreference(TopBarKey.self) { if $0.actions == nil { $0.actions = actions } }
    }

    /// The common one: a Refresh button (⌘R).
    func topBarRefresh(_ refresh: @escaping () async -> Void) -> some View {
        topBarActions([TopBarAction(id: "Refresh", symbol: "arrow.clockwise", shortcut: "r") { Task { await refresh() } }])
    }

    /// Lays the top bar over the top `TopBar.height` points of this view.
    func withTopBar() -> some View {
        overlayPreferenceValue(TopBarKey.self, alignment: .top) { TopBar(content: $0) }
    }
}

// MARK: - The bar

/// The window's top bar, drawn by Velvet rather than the system toolbar: sidebar toggle,
/// Back and the page's title on the left, search in the middle, the page's actions,
/// notifications and the account on the right.
struct TopBar: View {
    static let height: CGFloat = 52

    let content: TopBarContent
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ChromeButton("Toggle Sidebar", symbol: "sidebar.left") { app.toggleSidebar() }
                if content.back != nil || app.canGoBack {
                    ChromeButton("Back", symbol: "chevron.backward", shortcut: "[") {
                        if let back = content.back { back() } else { app.goBack() }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                if content.back == nil && app.canGoForward {
                    ChromeButton("Forward", symbol: "chevron.forward", shortcut: "]") { app.goForward() }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                if let title = content.title {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SearchField()
                .frame(minWidth: 180, idealWidth: 520, maxWidth: 520)
                .layoutPriority(1)

            HStack(spacing: 4) {
                ForEach(content.actions ?? []) { action in
                    ChromeButton(action.id, symbol: action.symbol, shortcut: action.shortcut, action: action.perform)
                        .disabled(action.disabled)
                }
                if app.authState == .signedIn { InboxButton() }
                AccountButton()
                    .padding(.leading, 6)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background {
            // Dragging the empty parts moves the window; double-clicking zooms it, like a title bar.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { app.mainWindow?.performZoom(nil) }
        }
        .animation(.smooth(duration: 0.2), value: content.back != nil || app.canGoBack)
        .animation(.smooth(duration: 0.2), value: app.canGoForward)
        .opacity(app.playerFullscreen ? 0 : 1)
    }
}

/// A round, borderless icon button that shows a soft circle on hover.
struct ChromeButton: View {
    let label: String
    let symbol: String
    var shortcut: KeyEquivalent?
    let action: () -> Void

    init(_ label: String, symbol: String, shortcut: KeyEquivalent? = nil, action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(ChromeButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: .command) })
    }
}

struct ChromeButtonStyle: ButtonStyle {
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, size: size)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hovering && isEnabled ? .primary : .secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(.primary.opacity(configuration.isPressed ? 0.14 : hovering && isEnabled ? 0.08 : 0)))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - Search

/// The search field. The text field exists only while you're typing in it: AppKit puts the
/// cursor in a window's first text field when the window opens, which would swallow the
/// player's single-key shortcuts (space, I, T…).
private struct SearchField: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    @State private var editing = false
    @State private var hovering = false

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Group {
                if editing {
                    TextField("Search YouTube", text: $app.searchText)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit {
                            app.submitSearch()
                            focused = false
                        }
                        .onExitCommand { focused = false }
                        .onAppear { focused = true }
                } else {
                    Text(app.searchText.isEmpty ? "Search YouTube" : app.searchText)
                        .foregroundStyle(app.searchText.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 14))
            if !app.searchText.isEmpty {
                Button { app.searchText = ""; startEditing() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            } else if !editing {
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            Capsule().fill(.primary.opacity(editing ? 0.04 : hovering ? 0.09 : 0.065))
        )
        .overlay(
            Capsule().strokeBorder(editing ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.primary.opacity(0.06)),
                                   lineWidth: editing ? 1.5 : 1)
        )
        .contentShape(Capsule())
        .onTapGesture { startEditing() }
        .onHover { hovering = $0 }
        .onChange(of: focused) { _, now in if !now { editing = false } }
        .animation(.easeOut(duration: 0.15), value: editing)
        .onChange(of: app.searchFocusRequest) { startEditing() }
        // ⌘K focuses search too (⌘F is in the View menu).
        .background {
            // Invisible rather than .hidden(): a hidden button's shortcut doesn't fire.
            Button("Search") { startEditing() }
                .keyboardShortcut("k")
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func startEditing() {
        if editing { focused = true } else { editing = true }
    }
}
