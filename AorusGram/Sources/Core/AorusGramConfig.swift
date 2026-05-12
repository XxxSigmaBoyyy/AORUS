import Foundation

/// Shared feature flags (UserDefaults). Public so `TelegramUI` (e.g. AppDelegate hooks) can read them.
public enum AorusGramConfig {
    public static let appName = "AorusGram"
    public static let version = "1.0.0"
    public static let officialChannelURL = "https://t.me/aorusgram"
    public static let officialChannelUsername = "aorusgram"

    public enum Feature: String, CaseIterable {
        case ghostMode          = "ghost_mode"
        case deletedMessages    = "deleted_messages"
        case antiSpam           = "anti_spam"
        case downloadAccel      = "download_accel"
        case siriShortcuts      = "siri_shortcuts"
        case unlimitedAccounts  = "unlimited_accounts"
        case glassUI            = "glass_ui"
        case messageScheduler   = "message_scheduler"
        case mediaManager       = "media_manager"
        case translator         = "translator"
        case voiceTranscription = "voice_transcription"
        case chatSummary        = "chat_summary"
        case antiScreenshot     = "anti_screenshot"
        case secretPin          = "secret_pin"
        case smartFolders       = "smart_folders"
        case streaks            = "streaks"
        case customIcons        = "custom_icons"
        case autoReply          = "auto_reply"
        case pinboard           = "pinboard"
    }

    public static func isEnabled(_ feature: Feature) -> Bool {
        return UserDefaults.standard.object(forKey: "aorusgram_feature_\(feature.rawValue)") as? Bool ?? defaultEnabled(feature)
    }

    public static func setEnabled(_ feature: Feature, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: "aorusgram_feature_\(feature.rawValue)")
    }

    private static func defaultEnabled(_ feature: Feature) -> Bool {
        switch feature {
        case .glassUI, .downloadAccel, .antiSpam, .deletedMessages: return true
        default: return false
        }
    }
}
