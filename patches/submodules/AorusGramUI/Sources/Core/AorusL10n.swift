import Foundation

// AorusGram localization.
//
// The client supports two languages — Russian and English — and follows the
// language selected inside Telegram. Resolution rule: a Telegram base-language
// code of "ru" (or any "ru-*" variant) → Russian; anything else → English.
//
// Two consumption paths:
//   1. UI with direct access to PresentationData → AorusL10n(strings.baseLanguageCode).
//   2. Cross-module / context-free call sites (e.g. the chat bubble that renders
//      deleted messages, or TelegramCore postbox markers) → AorusL10n.current,
//      which reads the resolved language persisted by AppDelegate's
//      presentationData observer under the "aorusgram_lang" UserDefaults key.
public enum AorusLang: String {
    case en
    case ru

    // Map a Telegram base-language code to one of the two supported languages.
    // Any language other than Russian falls back to English, as requested.
    public static func resolve(_ code: String?) -> AorusLang {
        guard let code = code?.lowercased() else { return .en }
        if code == "ru" || code.hasPrefix("ru-") || code.hasPrefix("ru_") {
            return .ru
        }
        return .en
    }

    // UserDefaults key shared with TelegramCore-injected code (postbox markers).
    public static let storageKey = "aorusgram_lang"

    // Persist the resolved language so context-free call sites can read it.
    public static func store(_ code: String?) {
        UserDefaults.standard.set(resolve(code).rawValue, forKey: storageKey)
    }

    // Best-effort current language for call sites without PresentationData.
    // Prefers the value persisted by the AppDelegate observer; before that fires
    // it falls back to the device language (Russian only for a Russian device).
    public static var current: AorusLang {
        if let raw = UserDefaults.standard.string(forKey: storageKey), let lang = AorusLang(rawValue: raw) {
            return lang
        }
        return resolve(Locale.preferredLanguages.first)
    }
}

public struct AorusL10n {
    public let lang: AorusLang

    public init(_ code: String?) {
        self.lang = AorusLang.resolve(code)
    }

    public init(lang: AorusLang) {
        self.lang = lang
    }

    public static var current: AorusL10n {
        return AorusL10n(lang: AorusLang.current)
    }

    private func t(_ ru: String, _ en: String) -> String {
        return self.lang == .ru ? ru : en
    }

    // MARK: Settings — section headers
    public var privacyHeader: String { t("ПРИВАТНОСТЬ", "PRIVACY") }
    public var aiHeader: String { t("AI ФУНКЦИИ", "AI FEATURES") }
    public var perfHeader: String { t("ПРОИЗВОДИТЕЛЬНОСТЬ", "PERFORMANCE") }
    public var uiHeader: String { t("ИНТЕРФЕЙС", "INTERFACE") }
    public var antiSpoofHeader: String { t("АНТИ-СПУФ", "ANTI-SPOOF") }
    public var accountBackupHeader: String { t("БЭКАП", "BACKUP") }
    public var aorusCodeHeader: String { t("AORUS CODE", "AORUS CODE") }

    // MARK: Settings — rows
    public var ghostMode: String { t("Режим призрака", "Ghost Mode") }
    public var deletedMessages: String { t("Удалённые сообщения", "Deleted Messages") }
    public var clearDeletedCache: String { t("Очистить кеш удалённых", "Clear Deleted Cache") }
    public var antiScreenshot: String { t("Скрытие экрана при записи", "Hide Screen While Recording") }
    public var voiceTranscription: String { t("Расшифровка голосовых", "Voice to Text") }
    public var chatSummary: String { t("Сводка чата", "Chat Summary") }
    public var translator: String { t("Переводчик", "Translator") }
    public var autoReply: String { t("Автоответчик", "Auto-Reply") }
    public var downloadAccel: String { t("Ускоритель загрузок", "Download Accelerator") }
    public var antiSpam: String { t("Анти-спам", "Anti-Spam") }
    public var ramShow: String { t("Показывать потребление RAM", "Show RAM Usage") }
    public var ramAutoClean: String { t("Автоочистка RAM", "Auto-Clean RAM") }
    public var ramInterval: String { t("Интервал очистки", "Cleanup Interval") }
    // Interval value, e.g. "60 мин" / "60 min".
    public func ramMinutes(_ n: Int) -> String { t("\(n) мин", "\(n) min") }
    public var glassUI: String { t("Glass UI", "Glass UI") }
    public var siriShortcuts: String { t("Siri Shortcuts", "Siri Shortcuts") }
    public var antiSpoofDeleted: String { t("Анти-спуф удалёнок", "Anti-Spoof Deletions") }
    public var antiSpoofOnline: String { t("Анти-спуф онлайна", "Anti-Spoof Online") }
    public var accountBackup: String { t("Бэкап аккаунтов", "Account Backup") }
    public var aorusCode: String { t("AorusCode", "AorusCode") }
    public var officialChannel: String { t("Официальный канал @aorusgram", "Official channel @aorusgram") }

    // MARK: Device Spoof
    public var deviceSpoofHeader: String { t("ДЕВАЙС-СПУФ", "DEVICE SPOOF") }
    public var deviceSpoof: String { t("Устройство", "Device") }
    public var deviceSpoofOff: String { t("Выкл.", "Off") }
    public var deviceSpoofCancel: String { t("Отмена", "Cancel") }

    // MARK: Media bypass
    public var bypassHeader: String { t("ОБХОД ОГРАНИЧЕНИЙ", "BYPASS") }
    public var bypassSavePaid: String { t("Сохранение платных медиа", "Save Paid Media") }
    public var bypassSaveViewOnce: String { t("Сохранение одноразовых", "Save View-Once Media") }
    public var bypassStoryDownload: String { t("Скачивание сторис", "Download Stories") }

    // MARK: Deleted / edited markers
    // Trailing space matches the original "Удалено " + relative-time layout.
    public var deletedPrefix: String { t("Удалено ", "Deleted ") }
}
