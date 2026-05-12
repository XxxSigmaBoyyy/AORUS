import Foundation
import UIKit

// Single entry point called once from AppDelegate after the account is ready.
// aorus_branding.py patches AppDelegate.swift to insert:
//   AorusGramBootstrap.shared.setup(accountPath:)
public final class AorusGramBootstrap {
    public static let shared = AorusGramBootstrap()
    private init() {}

    private var didSetup = false

    public func setup(accountPath: String? = nil) {
        guard !didSetup else { return }
        didSetup = true

        // Client spoof — must be before any MTProto connection is made
        ClientSpoofManager.applySwizzle()

        // Ghost Mode — restore persisted state + MTProto-level swizzle
        GhostModeManager.shared.load()
        GhostModeSwizzler.apply()

        // Deleted messages — register BGTask and schedule first sync
        DeletedMessagesCache.shared.registerBackgroundTask()
        DeletedMessagesCache.shared.scheduleBackgroundSync()

        // Anti-screenshot
        if AorusGramConfig.isEnabled(.antiScreenshot) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                AntiScreenshotManager.shared.enable()
            }
        }

        // Secret pin
        SecretPinManager.shared.load()

        // Streaks
        StreakManager.shared.tick()

        // Auto-reply
        AutoReplyManager.shared.load()

        // Anti-spam
        AntiSpamManager.shared.setEnabled(AorusGramConfig.isEnabled(.antiSpam))

        // Subscribe to TelegramCore delete events (cross-module NotificationCenter bridge)
        NotificationCenter.default.addObserver(
            forName: .aorusWillDeleteMessage,
            object: nil,
            queue: nil
        ) { note in
            DeletedMessagesCache.shared.handleWillDeleteNotification(note)
        }

        // Subscribe to incoming message events (injected by branding.py into AccountStateManager)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("aorusgram.didReceiveMessage"),
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleIncomingMessage(note)
        }

        observeAppLifecycle()
    }

    // MARK: - Incoming message handler (anti-spam + auto-reply)

    private func handleIncomingMessage(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let peerId = (info["peerId"] as? NSNumber)?.int64Value ?? 0
        let text   = info["text"]   as? String ?? ""

        // Anti-spam gate
        if AorusGramConfig.isEnabled(.antiSpam) {
            let verdict = AntiSpamManager.shared.check(peerId: peerId, text: text)
            if verdict.isSpam {
                AntiSpamManager.shared.processIncoming(peerId: peerId, text: text)
                return
            }
        }

        // Auto-reply
        if AorusGramConfig.isEnabled(.autoReply) {
            AutoReplyManager.shared.handleIncoming(peerId: peerId, text: text)
        }
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
