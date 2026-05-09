import Foundation
import SQLite3

// Кэширует все входящие сообщения до того как TelegramCore их удалит.
// Патч перехватывает deleteMessages в TelegramCore и сохраняет в локальную БД.
final class DeletedMessagesCache {
    static let shared = DeletedMessagesCache()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "aorusgram.deleted_messages", qos: .background)
    private let dbPath: String

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AorusGram", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("deleted_messages.sqlite").path
        openDB()
        createTable()
    }

    // MARK: - DB Setup

    private func openDB() {
        sqlite3_open(dbPath, &db)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS deleted_messages (
            id              INTEGER PRIMARY KEY,
            peer_id         INTEGER NOT NULL,
            sender_id       INTEGER,
            sender_name     TEXT,
            text            TEXT,
            date            INTEGER NOT NULL,
            deleted_at      INTEGER NOT NULL,
            media_path      TEXT,
            is_outgoing     INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_peer ON deleted_messages(peer_id, date DESC);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Cache incoming message (before deletion)

    func cacheMessage(
        id: Int32,
        peerId: Int64,
        senderId: Int64?,
        senderName: String?,
        text: String?,
        date: Int32,
        mediaPath: String?,
        isOutgoing: Bool
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let sql = """
            INSERT OR REPLACE INTO deleted_messages
            (id, peer_id, sender_id, sender_name, text, date, deleted_at, media_path, is_outgoing)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil)
            sqlite3_bind_int(stmt,  1, id)
            sqlite3_bind_int64(stmt, 2, peerId)
            sqlite3_bind_int64(stmt, 3, senderId ?? 0)
            sqlite3_bind_text(stmt, 4, senderName ?? "", -1, nil)
            sqlite3_bind_text(stmt, 5, text ?? "", -1, nil)
            sqlite3_bind_int(stmt,  6, date)
            sqlite3_bind_int64(stmt, 7, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_text(stmt, 8, mediaPath ?? "", -1, nil)
            sqlite3_bind_int(stmt,  9, isOutgoing ? 1 : 0)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Fetch deleted messages for chat

    func deletedMessages(peerId: Int64, limit: Int = 100) -> [DeletedMessage] {
        var results: [DeletedMessage] = []
        let sql = """
        SELECT id, peer_id, sender_id, sender_name, text, date, deleted_at, media_path, is_outgoing
        FROM deleted_messages WHERE peer_id = ? ORDER BY date DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, peerId)
        sqlite3_bind_int(stmt,  2, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(DeletedMessage(
                id:         sqlite3_column_int(stmt, 0),
                peerId:     sqlite3_column_int64(stmt, 1),
                senderId:   sqlite3_column_int64(stmt, 2),
                senderName: String(cString: sqlite3_column_text(stmt, 3)),
                text:       String(cString: sqlite3_column_text(stmt, 4)),
                date:       sqlite3_column_int(stmt, 5),
                deletedAt:  sqlite3_column_int64(stmt, 6),
                mediaPath:  String(cString: sqlite3_column_text(stmt, 7)),
                isOutgoing: sqlite3_column_int(stmt, 8) != 0
            ))
        }
        sqlite3_finalize(stmt)
        return results
    }

    func clearAll() {
        queue.async { [weak self] in
            sqlite3_exec(self?.db, "DELETE FROM deleted_messages;", nil, nil, nil)
        }
    }
}

struct DeletedMessage: Identifiable {
    let id: Int32
    let peerId: Int64
    let senderId: Int64
    let senderName: String
    let text: String
    let date: Int32
    let deletedAt: Int64
    let mediaPath: String
    let isOutgoing: Bool

    var deletedDate: Date { Date(timeIntervalSince1970: TimeInterval(deletedAt)) }
    var sentDate: Date    { Date(timeIntervalSince1970: TimeInterval(date)) }
}

// MARK: - Swizzle патч для deleteMessages

import ObjectiveC

final class DeletedMessagesSwizzler {
    static func apply() {
        guard
            let cls      = NSClassFromString("TelegramEngine"),
            let original = class_getInstanceMethod(cls, NSSelectorFromString("deleteMessages:forEveryone:")),
            let patched  = class_getInstanceMethod(DeletedMessagesSwizzler.self, #selector(ao_deleteMessages(_:forEveryone:)))
        else { return }
        method_exchangeImplementations(original, patched)
    }

    @objc private func ao_deleteMessages(_ messageIds: NSArray, forEveryone: Bool) {
        // Сохраняем перед удалением
        if AorusGramConfig.isEnabled(.deletedMessages) {
            for msgId in messageIds {
                if let id = msgId as? NSNumber {
                    // Получаем сообщение из кэша TelegramCore перед удалением
                    NotificationCenter.default.post(
                        name: .aorusCacheMessageBeforeDelete,
                        object: id
                    )
                }
            }
        }
        ao_deleteMessages(messageIds, forEveryone: forEveryone)
    }
}

extension Notification.Name {
    static let aorusCacheMessageBeforeDelete = Notification.Name("aorusgram_cache_before_delete")
}
