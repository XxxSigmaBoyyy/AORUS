import Foundation
import Combine

// Configurable auto-reply: sends a preset message automatically when a new
// message arrives while the user is in "away" state (manually toggled or
// scheduled). Deduplicates replies within a cooldown window per peer.
final class AutoReplyManager: ObservableObject {
    static let shared = AutoReplyManager()
    private init() {}

    @Published var isEnabled: Bool = false {
        didSet { persist() }
    }
    @Published var replyText: String = "Я сейчас недоступен. Отвечу позже." {
        didSet { persist() }
    }
    @Published var cooldownMinutes: Int = 60 {
        didSet { persist() }
    }
    @Published var skipGroups: Bool = true {
        didSet { persist() }
    }
    @Published var skipChannels: Bool = true {
        didSet { persist() }
    }

    // peerId → Date of last auto-reply
    private var lastReplied: [Int64: Date] = [:]
    private let queue = DispatchQueue(label: "aorusgram.autoreply")

    // MARK: - Persistence

    func load() {
        let d = UserDefaults.standard
        isEnabled       = d.bool(forKey: "aorus_ar_enabled")
        replyText       = d.string(forKey: "aorus_ar_text") ?? replyText
        cooldownMinutes = d.integer(forKey: "aorus_ar_cooldown").nonZero ?? 60
        skipGroups      = d.object(forKey: "aorus_ar_skip_groups") as? Bool ?? true
        skipChannels    = d.object(forKey: "aorus_ar_skip_channels") as? Bool ?? true
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(isEnabled,       forKey: "aorus_ar_enabled")
        d.set(replyText,       forKey: "aorus_ar_text")
        d.set(cooldownMinutes, forKey: "aorus_ar_cooldown")
        d.set(skipGroups,      forKey: "aorus_ar_skip_groups")
        d.set(skipChannels,    forKey: "aorus_ar_skip_channels")
    }

    // MARK: - Decision

    enum AutoReplyDecision {
        case send(String)
        case skip(String)
    }

    /// Called by the aorus_branding.py hook when a new incoming message arrives.
    /// Parameters: peerId (negative for groups/channels), isGroup, isChannel
    func decide(peerId: Int64, isGroup: Bool, isChannel: Bool) -> AutoReplyDecision {
        guard AorusGramConfig.isEnabled(.autoReply), isEnabled else {
            return .skip("feature disabled")
        }
        if skipGroups, isGroup   { return .skip("group skipped") }
        if skipChannels, isChannel { return .skip("channel skipped") }

        let cooldown = TimeInterval(cooldownMinutes * 60)
        let now = Date()

        var shouldSend = false
        queue.sync {
            if let last = lastReplied[peerId], now.timeIntervalSince(last) < cooldown {
                // still in cooldown
            } else {
                lastReplied[peerId] = now
                shouldSend = true
            }
        }
        return shouldSend ? .send(replyText) : .skip("in cooldown")
    }

    // Manual reset of a specific peer's cooldown (e.g., when user opens the chat)
    func resetCooldown(for peerId: Int64) {
        queue.async { self.lastReplied.removeValue(forKey: peerId) }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
