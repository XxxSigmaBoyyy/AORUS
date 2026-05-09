import Foundation

// MARK: - Model

public struct CachedDeletedMessage: Codable {
    public let id: Int32
    public let peerId: Int64
    public let senderName: String
    public let text: String
    public let sentDate: Date
    public let deletedDate: Date
    public let isOutgoing: Bool
    public let mediaPath: String

    public init(
        id: Int32, peerId: Int64, senderName: String, text: String,
        sentDate: Date, deletedDate: Date, isOutgoing: Bool, mediaPath: String
    ) {
        self.id = id
        self.peerId = peerId
        self.senderName = senderName
        self.text = text
        self.sentDate = sentDate
        self.deletedDate = deletedDate
        self.isOutgoing = isOutgoing
        self.mediaPath = mediaPath
    }
}

// MARK: - Cache

public final class DeletedMessagesCache {
    public static let shared = DeletedMessagesCache()
    private init() {}

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    private func key(for peerId: Int64) -> String {
        return "aorusgram_deleted_msgs_\(peerId)"
    }

    // MARK: - Read

    public func deletedMessages(peerId: Int64) -> [CachedDeletedMessage] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: key(for: peerId)),
              let msgs = try? decoder.decode([CachedDeletedMessage].self, from: data) else {
            return []
        }
        return msgs
    }

    // MARK: - Write

    public func cacheMessage(
        id: Int32, peerId: Int64, senderName: String, text: String,
        sentDate: Date, isOutgoing: Bool, mediaPath: String = ""
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard AorusGramManager.shared.saveDeletedMessages else { return }

        var msgs = _loadRaw(peerId: peerId)
        if !msgs.contains(where: { $0.id == id }) {
            let msg = CachedDeletedMessage(
                id: id, peerId: peerId, senderName: senderName, text: text,
                sentDate: sentDate, deletedDate: Date(),
                isOutgoing: isOutgoing, mediaPath: mediaPath
            )
            msgs.append(msg)
            // Keep max 200 messages per peer to bound storage
            if msgs.count > 200 { msgs.removeFirst(msgs.count - 200) }
            _save(msgs, peerId: peerId)
        }
    }

    public func markDeleted(id: Int32, peerId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        var msgs = _loadRaw(peerId: peerId)
        for i in msgs.indices where msgs[i].id == id {
            msgs[i] = CachedDeletedMessage(
                id: msgs[i].id, peerId: msgs[i].peerId,
                senderName: msgs[i].senderName, text: msgs[i].text,
                sentDate: msgs[i].sentDate, deletedDate: Date(),
                isOutgoing: msgs[i].isOutgoing, mediaPath: msgs[i].mediaPath
            )
        }
        _save(msgs, peerId: peerId)
    }

    public func clear(peerId: Int64) {
        UserDefaults.standard.removeObject(forKey: key(for: peerId))
    }

    // MARK: - Private helpers (call with lock held)

    private func _loadRaw(peerId: Int64) -> [CachedDeletedMessage] {
        guard let data = UserDefaults.standard.data(forKey: key(for: peerId)),
              let msgs = try? decoder.decode([CachedDeletedMessage].self, from: data) else {
            return []
        }
        return msgs
    }

    private func _save(_ msgs: [CachedDeletedMessage], peerId: Int64) {
        if let data = try? encoder.encode(msgs) {
            UserDefaults.standard.set(data, forKey: key(for: peerId))
        }
    }
}
