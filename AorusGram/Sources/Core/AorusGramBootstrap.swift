import Foundation
import UIKit

// Single entry point called once from AppDelegate after the account is ready.
// aorus_branding.py patches AppDelegate.swift to insert:
//   AorusGramBootstrap.shared.setup(accountPath:)
final class AorusGramBootstrap {
    static let shared = AorusGramBootstrap()
    private init() {}

    private var didSetup = false

    func setup(accountPath: String? = nil) {
        guard !didSetup else { return }
        didSetup = true

        // Deleted messages — register BGTask and schedule first sync
        DeletedMessagesCache.shared.registerBackgroundTask()
        DeletedMessagesCache.shared.scheduleBackgroundSync()

        // Ghost Mode — restore persisted state
        GhostModeManager.shared.load()

        // Anti-screenshot — attach to the key window when it's ready
        if AorusGramConfig.isEnabled(.antiScreenshot) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                AntiScreenshotManager.shared.enable()
            }
        }

        // Secret pin — load stored config
        SecretPinManager.shared.load()

        // Streaks — daily tick
        StreakManager.shared.tick()

        // Auto-reply — restore state
        AutoReplyManager.shared.load()

        // Client spoof — must be before any MTProto connection is made
        ClientSpoofManager.applySwizzle()

        // Swizzle all ghost-mode hooks
        GhostModeSwizzler.apply()

        // Subscribe to TelegramCore delete events (cross-module NotificationCenter bridge)
        NotificationCenter.default.addObserver(
            forName: .aorusWillDeleteMessage,
            object: nil,
            queue: nil
        ) { note in
            DeletedMessagesCache.shared.handleWillDeleteNotification(note)
        }

        observeAppLifecycle()
    }

    // MARK: - App lifecycle

    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        DeletedMessagesCache.shared.scheduleBackgroundSync()
        StreakManager.shared.tick()
    }

    @objc private func appDidEnterBackground() {
        DeletedMessagesCache.shared.scheduleBackgroundSync()
    }
}
