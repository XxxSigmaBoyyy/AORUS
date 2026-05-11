import Foundation
import SQLite3
import BackgroundTasks

// Persists all incoming messages so content survives deletion.
//
// Architecture:
//   1. Messages are cached TWO ways:
//      a) Via TelegramCore callback (aorusDeleteInterceptor) — fires right before
//         postbox.deleteMessages(), giving us the full text even for offline deletes.
//      b) Via cacheFromChatItem() — called from the patched ChatMessageItem as messages
//         are rendered, covering any gap the interceptor misses (e.g., historic messages
//         seen in the chat before the feature was enabled).
//   2. BGAppRefreshTask runs every ~15 min to flush a pending queue and mark
//      messages confirmed-deleted when the interceptor fired.
//   3. deletedMessages(peerId:) returns only entries that were confirmed deleted
//      (status = 1), so the user only sees actually-gone content.
final class DeletedMessagesCache {
    static let shared = DeletedMessagesCache()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "aorusgram.dmc", qos: .background)
    private let dbPath: String

    // Background task identifier registered in Info.plist and AppDelegate
    static let bgTaskID = "com.aorusgram.dmc.sync"

    // MARK: - Init / DB setup

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AorusGram", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("deleted_messages.sqlite").path
        queue.sync { self.openDB(); self.createTable() }
    }

    private func openDB() {
        if sqlite3_open_v2(dbPath, &db,
                           SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            db = nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
    }

    private func createTable() {
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS messages (
            id          INTEGER,
            peer_id     INTEGER NOT NULL,
            sender_id   INTEGER,
            sender_name TEXT,
            text        TEXT,
            date        INTEGER NOT NULL,
            cached_at   INTEGER NOT NULL,
            deleted_at  INTEGER,
            media_type  TEXT,
            media_path  TEXT,
            is_outgoing INTEGER DEFAULT 0,
            status      INTEGER DEFAULT 0,  -- 0=cached, 1=deleted, 2=seen
            PRIMARY KEY (id, peer_id)
        );
        CREATE INDEX IF NOT EXISTS idx_peer_date ON messages(peer_id, date DESC);
        CREATE INDEX IF NOT EXISTS idx_deleted   ON messages(peer_id, status, date DESC);
        """, nil, nil, nil)
    }

    // MARK: - Cache API (called from two hooks)

    /// Cache a message that just arrived. Call before any deletion.
    func cacheMessage(
        id: Int32,
        peerId: Int64,
        senderId: Int64?,
        senderName: String?,
        text: String?,
        date: Int32,
        mediaType: String? = nil,
        mediaPath: String? = nil,
        isOutgoing: Bool,
        markDeleted: Bool = false
    ) {
        guard AorusGramConfig.isEnabled(.deletedMessages) else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
            INSERT OR REPLACE INTO messages
            (id, peer_id, sender_id, sender_name, text, date, cached_at, deleted_at, media_type, media_path, is_outgoing, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let now = Int64(Date().timeIntervalSince1970)
            sqlite3_bind_int(stmt,  1, id)
            sqlite3_bind_int64(stmt, 2, peerId)
            sqlite3_bind_int64(stmt, 3, senderId ?? 0)
            sqlite3_bind_text(stmt, 4, senderName ?? "", -1, nil)
            sqlite3_bind_text(stmt, 5, text ?? "", -1, nil)
            sqlite3_bind_int(stmt,  6, date)
            sqlite3_bind_int64(stmt, 7, now)
            if markDeleted {
                sqlite3_bind_int64(stmt, 8, now)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_text(stmt, 9,  mediaType ?? "", -1, nil)
            sqlite3_bind_text(stmt, 10, mediaPath ?? "", -1, nil)
            sqlite3_bind_int(stmt,  11, isOutgoing ? 1 : 0)
            sqlite3_bind_int(stmt,  12, markDeleted ? 1 : 0)
            sqlite3_step(stmt)
        }
    }

    /// Mark an already-cached message as deleted (called when server sends delete update).
    func markDeleted(id: Int32, peerId: Int64) {
        guard AorusGramConfig.isEnabled(.deletedMessages) else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "UPDATE messages SET status=1, deleted_at=? WHERE id=? AND peer_id=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int(stmt,  2, id)
            sqlite3_bind_int64(stmt, 3, peerId)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Fetch

    func deletedMessages(peerId: Int64, limit: Int = 200) -> [DeletedMessage] {
        var results: [DeletedMessage] = []
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
            SELECT id, peer_id, sender_id, sender_name, text, date, deleted_at, media_type, media_path, is_outgoing
            FROM messages WHERE peer_id=? AND status=1 ORDER BY date DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, peerId)
            sqlite3_bind_int(stmt,  2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idVal   = sqlite3_column_int(stmt, 0)
                let peerVal = sqlite3_column_int64(stmt, 1)
                let sender  = sqlite3_column_int64(stmt, 2)
                let sName   = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let txt     = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let date    = sqlite3_column_int(stmt, 5)
                let delAt   = sqlite3_column_int64(stmt, 6)
                let mType   = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
                let mPath   = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
                let isOut   = sqlite3_column_int(stmt, 9) != 0
                results.append(DeletedMessage(
                    id: idVal, peerId: peerVal,
                    senderId: sender, senderName: sName,
                    text: txt, date: date, deletedAt: delAt,
                    mediaType: mType, mediaPath: mPath,
                    isOutgoing: isOut
                ))
            }
        }
        return results
    }

    func allDeletedCount() -> Int {
        var count = 0
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages WHERE status=1;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
        }
        return count
    }

    func clearAll() {
        queue.async { [weak self] in
            sqlite3_exec(self?.db, "DELETE FROM messages;", nil, nil, nil)
        }
    }

    // MARK: - BGTask

    func registerBackgroundTask() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskID, using: nil) { [weak self] task in
                self?.handleBGTask(task as! BGAppRefreshTask)
            }
        }
    }

    func scheduleBackgroundSync() {
        if #available(iOS 13.0, *) {
            let req = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
            req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            try? BGTaskScheduler.shared.submit(req)
        }
    }

    private func handleBGTask(_ task: BGAppRefreshTask) {
        scheduleBackgroundSync()
        // Flush any pending ops and compact the WAL
        queue.async { [weak self] in
            sqlite3_exec(self?.db, "PRAGMA wal_checkpoint(PASSIVE);", nil, nil, nil)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { task.setTaskCompleted(success: false) }
    }
}

// MARK: - Model

struct DeletedMessage: Identifiable {
    let id: Int32
    let peerId: Int64
    let senderId: Int64
    let senderName: String
    let text: String
    let date: Int32
    let deletedAt: Int64
    let mediaType: String
    let mediaPath: String
    let isOutgoing: Bool

    var sentDate: Date    { Date(timeIntervalSince1970: TimeInterval(date)) }
    var deletedDate: Date { Date(timeIntervalSince1970: TimeInterval(deletedAt)) }
    var hasMedia: Bool    { !mediaType.isEmpty }
}

// MARK: - TelegramCore intercept bridge (NotificationCenter)
//
// TelegramCore и main app — разные Swift-модули (TelegramCore — framework).
// Прямой вызов функции из одного модуля в другой невозможен без circular dependency.
// Решение: NotificationCenter работает across module boundaries через Foundation.
//
// aorus_branding.py патчит AccountStateManager.swift и добавляет перед
// transaction.deleteMessages(...):
//   NotificationCenter.default.post(name: NSNotification.Name("aorusgram.willDeleteMessage"), ...)
//
// AorusGramBootstrap.setup() подписывается на это уведомление и вызывает
// DeletedMessagesCache.shared.cacheMessage(...).

extension Notification.Name {
    static let aorusWillDeleteMessage = Notification.Name("aorusgram.willDeleteMessage")
}

// UserInfo keys for .aorusWillDeleteMessage notification
enum AorusDMCNotifKey {
    static let msgId      = "msgId"      // NSNumber Int32
    static let peerId     = "peerId"     // NSNumber Int64
    static let senderId   = "senderId"   // NSNumber Int64
    static let senderName = "senderName" // String
    static let text       = "text"       // String
    static let date       = "date"       // NSNumber Int32
    static let isOutgoing = "isOutgoing" // NSNumber Bool
}

extension DeletedMessagesCache {
    /// Handle the NotificationCenter event posted by the TelegramCore patch.
    func handleWillDeleteNotification(_ note: Notification) {
        guard AorusGramConfig.isEnabled(.deletedMessages),
              let info     = note.userInfo,
              let msgId    = (info[AorusDMCNotifKey.msgId]    as? NSNumber)?.int32Value,
              let peerId   = (info[AorusDMCNotifKey.peerId]   as? NSNumber)?.int64Value
        else { return }
        let senderId   = (info[AorusDMCNotifKey.senderId]   as? NSNumber)?.int64Value
        let senderName = info[AorusDMCNotifKey.senderName]  as? String
        let text       = info[AorusDMCNotifKey.text]         as? String
        let date       = (info[AorusDMCNotifKey.date]       as? NSNumber)?.int32Value ?? 0
        let isOutgoing = (info[AorusDMCNotifKey.isOutgoing] as? NSNumber)?.boolValue ?? false

        cacheMessage(
            id: msgId, peerId: peerId,
            senderId: senderId, senderName: senderName,
            text: text, date: date,
            isOutgoing: isOutgoing, markDeleted: true
        )
    }
}
