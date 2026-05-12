import Foundation
import Combine

// Tracks consecutive days of messaging with each contact.
// Streak data is stored in UserDefaults as a JSON-encoded dictionary:
//   key: "aorusgram_streaks"  value: [String(peerId): StreakRecord]
final class StreakManager: ObservableObject {
    static let shared = StreakManager()
    private init() { load() }

    @Published private(set) var streaks: [Int64: StreakRecord] = [:]

    private let udKey = "aorusgram_streaks_v2"
    private let calendar = Calendar.current

    // MARK: - Record a message event

    func recordMessage(peerId: Int64) {
        guard AorusGramConfig.isEnabled(.streaks) else { return }
        let today = calendar.startOfDay(for: Date())
        if var rec = streaks[peerId] {
            let lastDay = calendar.startOfDay(for: rec.lastMessageDate)
            let diff = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0
            switch diff {
            case 0:
                rec.todayCount += 1
            case 1:
                rec.currentStreak += 1
                rec.todayCount = 1
                rec.lastMessageDate = Date()
                if rec.currentStreak > rec.maxStreak {
                    rec.maxStreak = rec.currentStreak
                }
            default:
                rec.currentStreak = 1
                rec.todayCount = 1
                rec.lastMessageDate = Date()
            }
            streaks[peerId] = rec
        } else {
            streaks[peerId] = StreakRecord(
                peerId: peerId, currentStreak: 1, maxStreak: 1,
                lastMessageDate: Date(), todayCount: 1
            )
        }
        save()
    }

    func streak(for peerId: Int64) -> StreakRecord? {
        return streaks[peerId]
    }

    // Call once on app foreground to expire any broken streaks
    func tick() {
        guard AorusGramConfig.isEnabled(.streaks) else { return }
        let today = calendar.startOfDay(for: Date())
        var changed = false
        for (peerId, rec) in streaks {
            let lastDay = calendar.startOfDay(for: rec.lastMessageDate)
            let diff = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0
            if diff > 1 {
                var updated = rec
                updated.currentStreak = 0
                streaks[peerId] = updated
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([String: StreakRecord].self, from: data) else { return }
        streaks = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in
            guard let id = Int64(k) else { return nil }
            return (id, v)
        })
    }

    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues: streaks.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }
}

// MARK: - Model

struct StreakRecord: Codable {
    let peerId: Int64
    var currentStreak: Int
    var maxStreak: Int
    var lastMessageDate: Date
    var todayCount: Int

    var isActive: Bool { currentStreak > 0 }

    var emoji: String {
        switch currentStreak {
        case 0:        return ""
        case 1...6:    return "🔥"
        case 7...29:   return "🔥🔥"
        case 30...99:  return "💎"
        default:       return "👑"
        }
    }
}
