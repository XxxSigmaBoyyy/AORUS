import Foundation

final class AntiSpamManager {
    static let shared = AntiSpamManager()
    private init() { load() }

    private let defaultsKey = "aorusgram_antispam"
    private(set) var isEnabled = true
    private(set) var autoBlock = true
    private(set) var keywords: [String] = []
    private(set) var blockedPeerIds: Set<Int64> = []

    private let builtinSpamPatterns: [String] = [
        "заработ", "крипт", "инвест", "казино", "букмекер",
        "онлайн casino", "быстрый доход", "пассивный доход",
        "t.me/+", "free bitcoin", "nft drop", "airdrop",
        "переведи деньги", "срочно нужна помощь", "admin"
    ]

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        isEnabled  = saved.isEnabled
        autoBlock  = saved.autoBlock
        keywords   = saved.keywords
        blockedPeerIds = Set(saved.blockedPeerIds)
    }

    private func save() {
        let state = SavedState(
            isEnabled:      isEnabled,
            autoBlock:      autoBlock,
            keywords:       keywords,
            blockedPeerIds: Array(blockedPeerIds)
        )
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: defaultsKey)
    }

    // MARK: - API

    func setEnabled(_ value: Bool)   { isEnabled = value; save() }
    func setAutoBlock(_ value: Bool) { autoBlock = value; save() }

    func addKeyword(_ kw: String) {
        let clean = kw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !keywords.contains(clean) else { return }
        keywords.append(clean)
        save()
    }

    func removeKeyword(_ kw: String) {
        keywords.removeAll { $0 == kw }
        save()
    }

    func blockPeer(_ peerId: Int64) {
        blockedPeerIds.insert(peerId)
        save()
    }

    func unblockPeer(_ peerId: Int64) {
        blockedPeerIds.remove(peerId)
        save()
    }

    // MARK: - Check

    struct SpamVerdict {
        let isSpam: Bool
        let reason: SpamReason
    }

    enum SpamReason {
        case blockedUser, keyword(String), builtinPattern(String), clean
    }

    func check(peerId: Int64, text: String?) -> SpamVerdict {
        guard isEnabled else { return SpamVerdict(isSpam: false, reason: .clean) }

        if blockedPeerIds.contains(peerId) {
            return SpamVerdict(isSpam: true, reason: .blockedUser)
        }

        guard let text else { return SpamVerdict(isSpam: false, reason: .clean) }
        let lower = text.lowercased()

        for kw in keywords where lower.contains(kw) {
            return SpamVerdict(isSpam: true, reason: .keyword(kw))
        }

        for pattern in builtinSpamPatterns where lower.contains(pattern) {
            return SpamVerdict(isSpam: true, reason: .builtinPattern(pattern))
        }

        return SpamVerdict(isSpam: false, reason: .clean)
    }

    // Вызывается из перехватчика входящих сообщений
    func processIncoming(peerId: Int64, text: String?) {
        guard isEnabled else { return }
        let verdict = check(peerId: peerId, text: text)
        guard verdict.isSpam else { return }

        NotificationCenter.default.post(
            name: .aorusSpamDetected,
            object: nil,
            userInfo: ["peerId": peerId, "reason": "\(verdict.reason)"]
        )

        if autoBlock {
            blockPeer(peerId)
        }
    }

    // MARK: - Models

    private struct SavedState: Codable {
        var isEnabled: Bool
        var autoBlock: Bool
        var keywords: [String]
        var blockedPeerIds: [Int64]
    }
}

extension Notification.Name {
    static let aorusSpamDetected = Notification.Name("aorusgram_spam_detected")
}
