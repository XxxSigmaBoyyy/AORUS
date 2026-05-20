import Foundation
import CryptoKit
import Security

// MARK: - Account Backup Manager
//
// Backs up Telegram account auth data — `accounts-metadata` plus every
// `account-*` directory, excluding the re-downloadable media caches — into a
// single AES-256-GCM encrypted archive stored inside the app data directory.
// The archive's encryption key lives in the device Keychain and never leaves it.
//
// Restore is two-phase so it can never corrupt a live postbox:
//   1. prepareRestore()  — decrypts the archive into a staging directory and
//      raises the pending-restore flag (runs while the user is in the app).
//   2. applyPendingRestoreIfNeeded(rootPath:) — runs at the very start of the
//      next cold launch, BEFORE any postbox is opened, snapshots the current
//      account data for safety, then swaps the staged data into place.
public final class AccountBackupManager {
    public static let shared = AccountBackupManager()
    private init() {}

    // MARK: - Constants

    private let keychainService   = "aorusgram_account_backup"
    private let keychainKeyName   = "aes256_key_v1"
    private let rootPathKey       = "aorusgram_root_path"
    private let pendingRestoreKey = "aorusgram_pending_restore_v1"
    private let metaDateKey       = "aorusgram_backup_date_v1"
    private let metaCountKey      = "aorusgram_backup_accounts_v1"
    private let metaSizeKey       = "aorusgram_backup_size_v1"

    private static let archiveName  = "aorus-account-backup.enc"
    private static let stagingName  = ".aorus-restore-staging"
    private static let snapshotPrefix = ".aorus-prerestore-"
    private static let pendingFlagKey = "aorusgram_pending_restore_v1"

    // "AORSBK" + format version 1
    private let magic: [UInt8] = [0x41, 0x4F, 0x52, 0x53, 0x42, 0x4B, 0x01]

    private enum BackupError: Error { case truncated, corrupt }

    // MARK: - Root path

    // Mirrored to UserDefaults so the AorusGramUI copy of this manager reads the
    // same value. Set once by AorusGramBootstrap.setup(accountPath:).
    public var rootPath: String {
        get { UserDefaults.standard.string(forKey: rootPathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: rootPathKey) }
    }

    private var archiveURL: URL {
        URL(fileURLWithPath: rootPath).appendingPathComponent(Self.archiveName)
    }
    private var stagingURL: URL {
        URL(fileURLWithPath: rootPath).appendingPathComponent(Self.stagingName)
    }

    // MARK: - Public model

    public struct BackupInfo {
        public let date: Date
        public let accountCount: Int
        public let sizeBytes: Int64
    }

    public enum BackupOutcome {
        case success(BackupInfo)
        case failure(String)
    }

    // MARK: - Status

    public func hasBackup() -> Bool {
        return FileManager.default.fileExists(atPath: archiveURL.path) && loadKey() != nil
    }

    public func isRestorePending() -> Bool {
        return UserDefaults.standard.bool(forKey: pendingRestoreKey)
    }

    public func backupInfo() -> BackupInfo? {
        let ud = UserDefaults.standard
        guard hasBackup(), let date = ud.object(forKey: metaDateKey) as? Date else { return nil }
        return BackupInfo(
            date: date,
            accountCount: ud.integer(forKey: metaCountKey),
            sizeBytes: Int64(ud.integer(forKey: metaSizeKey))
        )
    }

    // Account record IDs present on disk (the `account-<id>` directory suffix).
    public func localAccountIds() -> [String] {
        let fm = FileManager.default
        guard !rootPath.isEmpty,
              let entries = try? fm.contentsOfDirectory(atPath: rootPath) else { return [] }
        return entries
            .filter { $0.hasPrefix("account-") && !$0.contains(".aorus") }
            .map { String($0.dropFirst("account-".count)) }
            .sorted()
    }

    // MARK: - Backup

    public func performBackup() -> BackupOutcome {
        guard !rootPath.isEmpty else { return .failure("Путь к данным аккаунтов недоступен") }
        let fm = FileManager.default

        var files: [(abs: String, rel: String)] = []
        collectBackupFiles(into: &files)
        guard !files.isEmpty else { return .failure("Нет данных аккаунтов для бэкапа") }

        let key = loadKey() ?? SymmetricKey(size: .bits256)

        let tmpURL = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(Self.archiveName + ".tmp")
        try? fm.removeItem(at: tmpURL)
        guard fm.createFile(atPath: tmpURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: tmpURL) else {
            return .failure("Не удалось создать файл бэкапа")
        }

        handle.write(Data(magic))
        for file in files {
            guard let content = fm.contents(atPath: file.abs),
                  let encPath = (try? AES.GCM.seal(Data(file.rel.utf8), using: key))?.combined,
                  let encBody = (try? AES.GCM.seal(content, using: key))?.combined else {
                handle.closeFile()
                try? fm.removeItem(at: tmpURL)
                return .failure("Ошибка шифрования данных")
            }
            handle.write(uint32LE(UInt32(encPath.count)))
            handle.write(encPath)
            handle.write(uint64LE(UInt64(encBody.count)))
            handle.write(encBody)
        }
        handle.write(uint32LE(0)) // end marker
        handle.closeFile()

        try? fm.removeItem(at: archiveURL)
        do {
            try fm.moveItem(at: tmpURL, to: archiveURL)
        } catch {
            try? fm.removeItem(at: tmpURL)
            return .failure("Не удалось сохранить бэкап")
        }

        guard saveKey(key) else {
            try? fm.removeItem(at: archiveURL)
            return .failure("Не удалось сохранить ключ в Keychain")
        }

        let attrs = try? fm.attributesOfItem(atPath: archiveURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let info = BackupInfo(date: Date(), accountCount: localAccountIds().count, sizeBytes: size)
        let ud = UserDefaults.standard
        ud.set(info.date, forKey: metaDateKey)
        ud.set(info.accountCount, forKey: metaCountKey)
        ud.set(Int(info.sizeBytes), forKey: metaSizeKey)
        return .success(info)
    }

    private func collectBackupFiles(into files: inout [(abs: String, rel: String)]) {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(atPath: rootPath) else { return }
        for name in top {
            let isMeta = (name == "accounts-metadata")
            let isAccount = name.hasPrefix("account-") && !name.contains(".aorus")
            guard isMeta || isAccount else { continue }
            let dirAbs = (rootPath as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirAbs, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                files.append((abs: dirAbs, rel: name))
                continue
            }
            enumerate(dirAbs: dirAbs, relBase: name, into: &files)
        }
    }

    private func enumerate(dirAbs: String, relBase: String,
                           into files: inout [(abs: String, rel: String)]) {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dirAbs) else { return }
        while let sub = en.nextObject() as? String {
            let lower = sub.lowercased()
            // Skip media / cache directories — large and re-downloadable.
            if lower.hasPrefix("postbox/media") || lower.contains("/media/")
                || lower == "media" || lower.hasPrefix("media/")
                || lower.contains("cache") || lower.contains("temp")
                || lower.contains("tmp") {
                en.skipDescendants()
                continue
            }
            let abs = (dirAbs as NSString).appendingPathComponent(sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: abs, isDirectory: &isDir), !isDir.boolValue else { continue }
            files.append((abs: abs, rel: relBase + "/" + sub))
        }
    }

    // MARK: - Restore phase 1: prepare

    public func prepareRestore() -> BackupOutcome {
        guard !rootPath.isEmpty else { return .failure("Путь к данным аккаунтов недоступен") }
        guard hasBackup(), let key = loadKey() else { return .failure("Бэкап не найден") }
        let fm = FileManager.default

        try? fm.removeItem(at: stagingURL)
        do {
            try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        } catch {
            return .failure("Не удалось создать папку восстановления")
        }

        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else {
            try? fm.removeItem(at: stagingURL)
            return .failure("Не удалось открыть бэкап")
        }

        let head = handle.readData(ofLength: magic.count)
        guard Array(head) == magic else {
            handle.closeFile()
            try? fm.removeItem(at: stagingURL)
            return .failure("Файл бэкапа повреждён")
        }

        do {
            while true {
                let pathLenData = handle.readData(ofLength: 4)
                guard pathLenData.count == 4 else { break }
                let encPathLen = readUInt32LE(pathLenData)
                if encPathLen == 0 { break } // end marker

                let encPath = handle.readData(ofLength: Int(encPathLen))
                guard encPath.count == Int(encPathLen) else { throw BackupError.truncated }
                let bodyLenData = handle.readData(ofLength: 8)
                guard bodyLenData.count == 8 else { throw BackupError.truncated }
                let encBodyLen = readUInt64LE(bodyLenData)
                let encBody = handle.readData(ofLength: Int(encBodyLen))
                guard encBody.count == Int(encBodyLen) else { throw BackupError.truncated }

                let relData = try AES.GCM.open(AES.GCM.SealedBox(combined: encPath), using: key)
                let body = try AES.GCM.open(AES.GCM.SealedBox(combined: encBody), using: key)
                guard let rel = String(data: relData, encoding: .utf8),
                      isSafeRelativePath(rel) else { throw BackupError.corrupt }

                let dest = stagingURL.appendingPathComponent(rel)
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try body.write(to: dest)
            }
        } catch {
            handle.closeFile()
            try? fm.removeItem(at: stagingURL)
            return .failure("Ошибка расшифровки бэкапа")
        }
        handle.closeFile()

        UserDefaults.standard.set(true, forKey: pendingRestoreKey)
        let info = backupInfo()
            ?? BackupInfo(date: Date(), accountCount: localAccountIds().count, sizeBytes: 0)
        return .success(info)
    }

    public func cancelPendingRestore() {
        UserDefaults.standard.set(false, forKey: pendingRestoreKey)
        try? FileManager.default.removeItem(at: stagingURL)
    }

    // Reject path traversal — only `accounts-metadata` and `account-*` roots allowed.
    private func isSafeRelativePath(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") { return false }
        let comps = path.split(separator: "/").map(String.init)
        if comps.contains("..") || comps.contains(".") { return false }
        guard let first = comps.first else { return false }
        return first == "accounts-metadata" || first.hasPrefix("account-")
    }

    // MARK: - Restore phase 2: apply at launch

    // Called from AppDelegate immediately after `rootPath` is known and BEFORE
    // any postbox / account context is created.
    public static func applyPendingRestoreIfNeeded(rootPath: String) {
        let ud = UserDefaults.standard
        guard ud.bool(forKey: pendingFlagKey), !rootPath.isEmpty else { return }
        // Clear the flag up-front — a restore must never loop and brick every launch.
        ud.set(false, forKey: pendingFlagKey)

        let fm = FileManager.default
        let staging = URL(fileURLWithPath: rootPath).appendingPathComponent(stagingName)
        guard fm.fileExists(atPath: staging.path),
              let staged = try? fm.contentsOfDirectory(atPath: staging.path),
              !staged.isEmpty else {
            try? fm.removeItem(at: staging)
            return
        }

        // Drop snapshots from earlier restores — keep only the one we make now,
        // otherwise old account data (incl. media caches) accumulates forever.
        if let rootEntries = try? fm.contentsOfDirectory(atPath: rootPath) {
            for name in rootEntries where name.hasPrefix(snapshotPrefix) {
                try? fm.removeItem(at: URL(fileURLWithPath: rootPath).appendingPathComponent(name))
            }
        }

        // Snapshot whatever currently occupies those top-level slots, so a failed
        // or unwanted restore stays recoverable.
        let snapshot = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(snapshotPrefix + String(Int(Date().timeIntervalSince1970)))
        try? fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for name in staged {
            let current = URL(fileURLWithPath: rootPath).appendingPathComponent(name)
            if fm.fileExists(atPath: current.path) {
                try? fm.moveItem(at: current, to: snapshot.appendingPathComponent(name))
            }
        }

        var allMoved = true
        for name in staged {
            let src = staging.appendingPathComponent(name)
            let dst = URL(fileURLWithPath: rootPath).appendingPathComponent(name)
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                allMoved = false
            }
        }
        try? fm.removeItem(at: staging)

        if !allMoved {
            // Roll back from the snapshot.
            for name in staged {
                let dst = URL(fileURLWithPath: rootPath).appendingPathComponent(name)
                let snap = snapshot.appendingPathComponent(name)
                if fm.fileExists(atPath: snap.path) {
                    try? fm.removeItem(at: dst)
                    try? fm.moveItem(at: snap, to: dst)
                }
            }
        }
    }

    // MARK: - Delete

    public func deleteBackup() {
        try? FileManager.default.removeItem(at: archiveURL)
        deleteKey()
        let ud = UserDefaults.standard
        ud.removeObject(forKey: metaDateKey)
        ud.removeObject(forKey: metaCountKey)
        ud.removeObject(forKey: metaSizeKey)
    }

    // MARK: - Keychain

    private func saveKey(_ key: SymmetricKey) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKeyName,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKeyName,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    private func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKeyName,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Byte helpers (little-endian, version-safe)

    private func uint32LE(_ v: UInt32) -> Data {
        return Data([
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ])
    }

    private func uint64LE(_ v: UInt64) -> Data {
        var bytes = [UInt8]()
        for i in 0..<8 { bytes.append(UInt8((v >> (UInt64(i) * 8)) & 0xFF)) }
        return Data(bytes)
    }

    private func readUInt32LE(_ d: Data) -> UInt32 {
        guard d.count >= 4 else { return 0 }
        let b = [UInt8](d)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    private func readUInt64LE(_ d: Data) -> UInt64 {
        guard d.count >= 8 else { return 0 }
        let b = [UInt8](d)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[i]) << (UInt64(i) * 8) }
        return v
    }
}
