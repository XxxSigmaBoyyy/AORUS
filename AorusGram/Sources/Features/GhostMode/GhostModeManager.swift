import Foundation

// Патч применяется к TelegramCore — перехватывает исходящие presence-апдейты
// и блокирует отправку read receipts когда Ghost Mode активен.
final class GhostModeManager {
    static let shared = GhostModeManager()
    private init() {}

    private(set) var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "aorusgram_ghost_mode")
            NotificationCenter.default.post(name: .ghostModeChanged, object: isEnabled)
        }
    }

    private(set) var hideLastSeen: Bool = true
    private(set) var blockReadReceipts: Bool = true
    private(set) var hidePeekStatus: Bool = true   // не отправлять "печатает..."

    func load() {
        isEnabled = UserDefaults.standard.bool(forKey: "aorusgram_ghost_mode")
    }

    func toggle() {
        isEnabled.toggle()
    }

    func configure(hideLastSeen: Bool, blockReadReceipts: Bool, hidePeekStatus: Bool) {
        self.hideLastSeen = hideLastSeen
        self.blockReadReceipts = blockReadReceipts
        self.hidePeekStatus = hidePeekStatus
    }

    // Вызывается из swizzled updatePeerPresence в TelegramCore
    func shouldSendOnlinePresence() -> Bool {
        return !isEnabled
    }

    // Вызывается из swizzled markMessagesAsRead в TelegramCore
    func shouldSendReadReceipt(peerId: Int64) -> Bool {
        guard isEnabled, blockReadReceipts else { return true }
        // Всегда блокируем read receipts в ghost mode
        return false
    }

    // Вызывается из swizzled updateTypingActivity
    func shouldSendTypingIndicator() -> Bool {
        guard isEnabled, hidePeekStatus else { return true }
        return false
    }
}

extension Notification.Name {
    static let ghostModeChanged = Notification.Name("aorusgram_ghost_mode_changed")
}

// MARK: - Swizzle патчи для TelegramCore

import ObjectiveC

final class GhostModeSwizzler {
    static func apply() {
        // Перехват отправки presence (онлайн/оффлайн)
        swizzlePresence()
        // Перехват отправки read receipts
        swizzleReadReceipts()
        // Перехват typing indicator
        swizzleTyping()
    }

    private static func swizzlePresence() {
        guard
            let cls = NSClassFromString("TelegramEnginePresence") ?? NSClassFromString("AccountContext"),
            let original = class_getInstanceMethod(cls, NSSelectorFromString("updatePresence:")),
            let patched  = class_getInstanceMethod(GhostModeSwizzler.self, #selector(ao_updatePresence(_:)))
        else { return }
        method_exchangeImplementations(original, patched)
    }

    private static func swizzleReadReceipts() {
        guard
            let cls = NSClassFromString("TelegramEngine"),
            let original = class_getInstanceMethod(cls, NSSelectorFromString("markAllMessagesAsRead:")),
            let patched  = class_getInstanceMethod(GhostModeSwizzler.self, #selector(ao_markAllMessagesAsRead(_:)))
        else { return }
        method_exchangeImplementations(original, patched)
    }

    private static func swizzleTyping() {
        guard
            let cls = NSClassFromString("TelegramEngine"),
            let original = class_getInstanceMethod(cls, NSSelectorFromString("requestEditMessage:attributes:")),
            let patched  = class_getInstanceMethod(GhostModeSwizzler.self, #selector(ao_requestTyping(_:)))
        else { return }
        method_exchangeImplementations(original, patched)
    }

    @objc private func ao_updatePresence(_ presence: AnyObject) {
        guard GhostModeManager.shared.shouldSendOnlinePresence() else { return }
        ao_updatePresence(presence) // вызов оригинала (swizzled)
    }

    @objc private func ao_markAllMessagesAsRead(_ peerId: AnyObject) {
        guard GhostModeManager.shared.shouldSendReadReceipt(peerId: 0) else { return }
        ao_markAllMessagesAsRead(peerId)
    }

    @objc private func ao_requestTyping(_ attr: AnyObject) {
        guard GhostModeManager.shared.shouldSendTypingIndicator() else { return }
        ao_requestTyping(attr)
    }
}
