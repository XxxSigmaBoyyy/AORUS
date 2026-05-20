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

        // Persist the account-data root so AccountBackupManager can locate the
        // accounts-metadata / account-* directories for backup & restore.
        if let accountPath = accountPath, !accountPath.isEmpty {
            AccountBackupManager.shared.rootPath = accountPath
        }

        // Integrity check — runs async so it never blocks app launch
        DispatchQueue.global(qos: .utility).async {
            AorusTamperGuard.shared.verify()
        }

        // Client spoof — must be before any MTProto connection is made
        ClientSpoofManager.applySwizzle()

        // Ghost Mode — restore persisted state only. The MTProto-level ObjC swizzle
        // (GhostModeSwizzler) was REMOVED because its body.perform("serialize") path
        // caused intermittent crashes on toggling. Source-level patches injected by
        // aorus_branding.py (ManagedAccountPresence, ManagedLocalInputActivities,
        // SynchronizePeerReadState) are the sole and sufficient enforcement layer now.
        GhostModeManager.shared.load()

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

        // Anti-spoof — touch shared instance so load() runs and mirrors current
        // dictionary state to flat UserDefaults keys that TelegramCore patches read.
        _ = AntiSpoofManager.shared

        // Subscribe to TelegramCore delete events (cross-module NotificationCenter bridge)
        NotificationCenter.default.addObserver(
            forName: .aorusWillDeleteMessage,
            object: nil,
            queue: nil
        ) { note in
            DeletedMessagesCache.shared.handleWillDeleteNotification(note)
        }
        NotificationCenter.default.addObserver(
            forName: .aorusWillDeleteMessageGlobalId,
            object: nil,
            queue: nil
        ) { note in
            DeletedMessagesCache.shared.handleWillDeleteByGlobalIdNotification(note)
        }
        NotificationCenter.default.addObserver(
            forName: .aorusWillEditMessage,
            object: nil,
            queue: nil
        ) { note in
            DeletedMessagesCache.shared.handleWillEditNotification(note)
        }

        // Subscribe to incoming message events (injected by branding.py into AccountStateManager)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("aorusgram.didReceiveMessage"),
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleIncomingMessage(note)
        }

        // Siri Shortcuts — donate on bootstrap if enabled, re-donate / clear when toggled.
        if #available(iOS 16.0, *) {
            if AorusGramConfig.isEnabled(.siriShortcuts) {
                SiriShortcutsManager.shared.donateAllDefaults()
            }
            NotificationCenter.default.addObserver(
                forName: .aorusSettingsChanged,
                object: nil,
                queue: .main
            ) { _ in
                if AorusGramConfig.isEnabled(.siriShortcuts) {
                    SiriShortcutsManager.shared.donateAllDefaults()
                } else {
                    NSUserActivity.deleteAllSavedUserActivities(completionHandler: {})
                }
            }
        }

        observeAppLifecycle()
    }

    // MARK: - Incoming message handler (anti-spam + auto-reply)

    private func handleIncomingMessage(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let peerId = (info["peerId"] as? NSNumber)?.int64Value ?? 0
        let text   = info["text"]   as? String ?? ""

        // Pre-cache for deleted-messages feature — captures content before any deletion.
        // Without this the cache only sees messages whose delete-hook fires, which is unreliable.
        DeletedMessagesCache.shared.handleIncomingNotification(note)

        // Anti-spoof online — record peer activity so we can show real "last seen"
        // even when the peer hides it client-side. Each incoming message is direct
        // proof they were online at that moment.
        let senderId = (note.userInfo?["senderId"] as? NSNumber)?.int64Value ?? peerId
        AntiSpoofManager.shared.recordActivity(peerId: senderId, kind: .message)

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
