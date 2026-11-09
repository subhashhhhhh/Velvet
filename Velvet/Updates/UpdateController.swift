// Checks GitHub for a newer Velvet once a day and installs it from Settings › About.
// Homebrew stays out of the way: the cask declares `auto_updates true`, so `brew upgrade`
// leaves a self-updating Velvet alone.

import AppKit
import OSLog
import UserNotifications

@Observable
final class UpdateController {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableRelease)
        case installing(AvailableRelease, UpdateInstaller.Phase)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?

    /// Only a release build signed with Velvet's certificate can check a download against
    /// itself; any other build offers the release page instead.
    let canInstall = BundleSignature.canVerifyUpdates

    /// Called when an automatic check finds a release, to point the user at it.
    var onFound: ((AvailableRelease) -> Void)?

    private static let lastCheckedKey = "updates.lastChecked"
    private static let announcedKey = "updates.announcedVersion"
    private static let checkInterval: TimeInterval = 24 * 3600
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Updates")
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var installation: Task<Void, Never>?

    init() {
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date
    }

    var availableRelease: AvailableRelease? {
        switch state {
        case .available(let release), .installing(let release, _): release
        default: nil
        }
    }

    /// Checks once a day while `enabled()` says so.
    func start(enabled: @escaping () -> Bool) {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            // Stay out of the launch rush.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                guard let self else { return }
                if enabled(), self.isCheckDue { await self.check(userInitiated: false) }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private var isCheckDue: Bool {
        guard let lastChecked else { return true }
        return Date().timeIntervalSince(lastChecked) >= Self.checkInterval
    }

    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        if case .installing = state { return }
        if case .checking = state { return }
        if userInitiated { state = .checking }
        let release: AvailableRelease?
        do {
            release = try await ReleaseFeed.latest()
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated { state = .failed(error.localizedDescription) }
            return
        }
        lastChecked = .now
        UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)

        guard let release, let current = AppVersion.current, release.version > current else {
            state = .upToDate
            return
        }
        log.info("Velvet \(release.version.description, privacy: .public) is available")
        state = .available(release)
        // Announce each version once; a manual check already shows it in Settings.
        let announced = UserDefaults.standard.string(forKey: Self.announcedKey)
        if !userInitiated, announced != release.version.description {
            UserDefaults.standard.set(release.version.description, forKey: Self.announcedKey)
            onFound?(release)
        }
    }

    func install() {
        guard case .available(let release) = state, installation == nil else { return }
        guard canInstall else { NSWorkspace.shared.open(release.pageURL); return }
        let installer = UpdateInstaller.standard
        state = .installing(release, .downloading(received: 0, expected: release.archiveSize))
        installation = Task { [weak self] in
            do {
                try await installer.install(release) { phase in
                    Task { @MainActor in
                        guard let self, case .installing = self.state else { return }
                        self.state = .installing(release, phase)
                    }
                }
                Relauncher.relaunchAfterExit(installer.bundleURL)
                NSApp.terminate(nil)
            } catch is CancellationError {
                self?.state = .available(release)
            } catch {
                self?.log.error("Update install failed: \(error.localizedDescription, privacy: .public)")
                self?.state = .failed(error.localizedDescription)
            }
            self?.installation = nil
        }
    }

    func cancelInstall() {
        installation?.cancel()
    }
}
