import Foundation
import Intents
import IntentsUI

// MARK: - Intent definitions (дублируем Intent для Siri)

@available(iOS 16.0, *)
final class SiriShortcutsManager {
    static let shared = SiriShortcutsManager()
    private init() {}

    enum ShortcutType: String, CaseIterable {
        case sendMessage      = "SendTelegramMessage"
        case openChat         = "OpenTelegramChat"
        case toggleGhostMode  = "ToggleGhostMode"
        case readUnread       = "ReadUnreadMessages"
        case searchMessage    = "SearchTelegramMessage"

        var suggestedPhrase: String {
            switch self {
            case .sendMessage:     return "Написать в Telegram"
            case .openChat:        return "Открыть чат"
            case .toggleGhostMode: return "Включить режим призрака"
            case .readUnread:      return "Прочитать непрочитанные"
            case .searchMessage:   return "Найти сообщение"
            }
        }
    }

    // MARK: - Donate shortcuts to Siri

    func donateShortcut(_ type: ShortcutType, contact: String? = nil) {
        let activity = NSUserActivity(activityType: "com.aorusgram.\(type.rawValue)")
        activity.title          = type.suggestedPhrase
        activity.isEligibleForSearch      = true
        activity.isEligibleForPrediction  = true
        activity.suggestedInvocationPhrase = type.suggestedPhrase

        if let contact {
            activity.userInfo = ["contact": contact]
        }

        activity.becomeCurrent()
    }

    func donateAllDefaults() {
        ShortcutType.allCases.forEach { donate($0) }
    }

    private func donate(_ type: ShortcutType) {
        donateShortcut(type)
    }

    // MARK: - Handle Siri intent from AppDelegate

    func handle(activity: NSUserActivity) -> Bool {
        guard let type = ShortcutType(rawValue: activity.activityType
            .replacingOccurrences(of: "com.aorusgram.", with: "")) else { return false }

        switch type {
        case .toggleGhostMode:
            GhostModeManager.shared.toggle()
            NotificationCenter.default.post(name: .siriActionPerformed, object: type)
            return true

        case .readUnread:
            NotificationCenter.default.post(name: .siriActionPerformed, object: type)
            return true

        case .sendMessage:
            if let contact = activity.userInfo?["contact"] as? String {
                NotificationCenter.default.post(
                    name: .siriOpenChat,
                    object: nil,
                    userInfo: ["contact": contact, "focusInput": true]
                )
            }
            return true

        case .openChat:
            if let contact = activity.userInfo?["contact"] as? String {
                NotificationCenter.default.post(
                    name: .siriOpenChat,
                    object: nil,
                    userInfo: ["contact": contact]
                )
            }
            return true

        case .searchMessage:
            NotificationCenter.default.post(name: .siriOpenSearch, object: nil)
            return true
        }
    }

    // MARK: - Add to Siri button helper

    func addToSiriViewController(for type: ShortcutType) -> INUIAddVoiceShortcutViewController? {
        let activity = NSUserActivity(activityType: "com.aorusgram.\(type.rawValue)")
        activity.title                     = type.suggestedPhrase
        activity.suggestedInvocationPhrase = type.suggestedPhrase
        activity.isEligibleForPrediction   = true

        guard let shortcut = INShortcut(userActivity: activity) else { return nil }
        let vc = INUIAddVoiceShortcutViewController(shortcut: shortcut)
        return vc
    }
}

extension Notification.Name {
    static let siriActionPerformed = Notification.Name("aorusgram_siri_action")
    static let siriOpenChat        = Notification.Name("aorusgram_siri_open_chat")
    static let siriOpenSearch      = Notification.Name("aorusgram_siri_open_search")
}
