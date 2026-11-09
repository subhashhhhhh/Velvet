import SwiftUI

@main
struct VelvetApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    // Quitting doesn't change scenePhase; persist the final position here.
                    app.watching?.close()
                    app.progress.saveNow()
                }
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        // Before the window has a saved size of its own (the minimum is too small for a grid).
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button(app.isSidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar") { app.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                Button("Search YouTube") { app.searchFocusRequest += 1 }
                    .keyboardShortcut("f")
                Divider()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { app.watching?.saveProgress(); app.progress.saveNow() }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
