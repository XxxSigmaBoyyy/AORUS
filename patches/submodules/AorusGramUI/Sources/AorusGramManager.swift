import Foundation
import UIKit

// MARK: - Central Config

public final class AorusGramManager {
    public static let shared = AorusGramManager()
    private init() { load() }

    public let version = "1.0.0"
    public let channelURL = "https://t.me/aorusgram"
    public let channelUsername = "aorusgram"

    // MARK: - Feature flags

    public var ghostMode: Bool        = false { didSet { save() } }
    public var blockReadReceipts: Bool = true  { didSet { save() } }
    public var hideTyping: Bool        = true  { didSet { save() } }
    public var saveDeletedMessages: Bool = true { didSet { save() } }
    public var antiSpamEnabled: Bool   = true  { didSet { save() } }
    public var downloadAccel: Bool     = true  { didSet { save() } }
    public var glassUI: Bool           = true  { didSet { save() } }
    public var voiceTranscription: Bool = false { didSet { save() } }
    public var chatSummary: Bool       = false { didSet { save() } }
    public var translator: Bool        = false { didSet { save() } }
    public var antiScreenshot: Bool    = false { didSet { save() } }
    public var streaks: Bool           = false { didSet { save() } }
    public var siriShortcuts: Bool     = false { didSet { save() } }
    public var autoReply: Bool         = false { didSet { save() } }

    // RAM management (replaces the former Streak feature in the Performance section).
    public var ramShow: Bool           = false { didSet { save() } }
    public var ramAutoClean: Bool      = false { didSet { save() } }
    public var ramInterval: Int        = 60    { didSet { save() } }   // minutes

    private let key = "aorusgram_settings_v1"

    private func load() {
        // Always mirror current values to the flat keys read by source patches —
        // this also catches fresh installs where the dictionary doesn't exist yet
        // (defaults apply, then save() is called once).
        defer {
            let ud = UserDefaults.standard
            ud.set(ghostMode,           forKey: "aorusgram_ghost_mode")
            ud.set(saveDeletedMessages, forKey: "aorusgram_feature_deleted_messages")
            ud.set(downloadAccel,       forKey: "aorusgram_feature_download_accel")
        }
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return }
        ghostMode           = d["ghostMode"]           as? Bool ?? false
        blockReadReceipts   = d["blockReadReceipts"]   as? Bool ?? true
        hideTyping          = d["hideTyping"]          as? Bool ?? true
        saveDeletedMessages = d["saveDeletedMessages"] as? Bool ?? true
        antiSpamEnabled     = d["antiSpamEnabled"]     as? Bool ?? true
        downloadAccel       = d["downloadAccel"]       as? Bool ?? true
        glassUI             = d["glassUI"]             as? Bool ?? true
        voiceTranscription  = d["voiceTranscription"]  as? Bool ?? false
        chatSummary         = d["chatSummary"]         as? Bool ?? false
        translator          = d["translator"]          as? Bool ?? false
        antiScreenshot      = d["antiScreenshot"]      as? Bool ?? false
        streaks             = d["streaks"]             as? Bool ?? false
        siriShortcuts       = d["siriShortcuts"]       as? Bool ?? false
        autoReply           = d["autoReply"]           as? Bool ?? false
        ramShow             = d["ramShow"]             as? Bool ?? false
        ramAutoClean        = d["ramAutoClean"]        as? Bool ?? false
        ramInterval         = d["ramInterval"]         as? Int  ?? 60
    }

    private func save() {
        UserDefaults.standard.set([
            "ghostMode":           ghostMode,
            "blockReadReceipts":   blockReadReceipts,
            "hideTyping":          hideTyping,
            "saveDeletedMessages": saveDeletedMessages,
            "antiSpamEnabled":     antiSpamEnabled,
            "downloadAccel":       downloadAccel,
            "glassUI":             glassUI,
            "voiceTranscription":  voiceTranscription,
            "chatSummary":         chatSummary,
            "translator":          translator,
            "antiScreenshot":      antiScreenshot,
            "streaks":             streaks,
            "siriShortcuts":       siriShortcuts,
            "autoReply":           autoReply,
            "ramShow":             ramShow,
            "ramAutoClean":        ramAutoClean,
            "ramInterval":         ramInterval,
        ], forKey: key)

        let ud = UserDefaults.standard
        ud.set(ghostMode,           forKey: "aorusgram_ghost_mode")
        ud.set(saveDeletedMessages, forKey: "aorusgram_feature_deleted_messages")
        ud.set(antiScreenshot,      forKey: "aorusgram_feature_anti_screenshot")
        ud.set(voiceTranscription,  forKey: "aorusgram_feature_voice_transcription")
        ud.set(translator,          forKey: "aorusgram_feature_translator")
        ud.set(chatSummary,         forKey: "aorusgram_feature_chat_summary")
        ud.set(autoReply,           forKey: "aorusgram_feature_auto_reply")
        ud.set(antiSpamEnabled,     forKey: "aorusgram_feature_anti_spam")
        ud.set(downloadAccel,       forKey: "aorusgram_feature_download_accel")
        ud.set(glassUI,             forKey: "aorusgram_feature_glass_ui")
        ud.set(streaks,             forKey: "aorusgram_feature_streaks")
        ud.set(siriShortcuts,       forKey: "aorusgram_feature_siri_shortcuts")

        if antiScreenshot {
            AntiScreenshotManager.shared.enable()
        } else {
            AntiScreenshotManager.shared.disable()
        }

        NotificationCenter.default.post(name: .aorusSettingsChanged, object: nil)
    }

    // MARK: - Ghost Mode

    public func shouldSendOnlinePresence() -> Bool  { !ghostMode }
    public func shouldSendReadReceipt() -> Bool     { !ghostMode || !blockReadReceipts }
    public func shouldSendTypingIndicator() -> Bool { !ghostMode || !hideTyping }

    // MARK: - Bootstrap (call from AppDelegate/AppLock)

    public func bootstrap() {
        if downloadAccel  { applyDownloadAcceleration() }
        if siriShortcuts  { donateSiriShortcuts() }
    }

    private func applyDownloadAcceleration() {
        UserDefaults.standard.set(8, forKey: "aorusgram_mtproto_maxDownloadConnections")
        UserDefaults.standard.set(2 * 1024 * 1024, forKey: "aorusgram_mtproto_downloadChunkSize")
    }

    private func donateSiriShortcuts() {
        let activity = NSUserActivity(activityType: "com.aorusgram.ToggleGhostMode")
        activity.title = "Включить режим призрака"
        activity.isEligibleForPrediction = true
        // suggestedInvocationPhrase requires Intents framework — skip to avoid dep
        activity.becomeCurrent()
    }
}

public extension Notification.Name {
    static let aorusSettingsChanged = Notification.Name("aorusgram_settings_changed")
}
