import Foundation
import CryptoKit
import UIKit

// AorusCode — офлайн-система активационных кодов.
//
// Формат: AORUS-XXXX-XXXX-XXXX-XXXX (без учёта дефисов = 21 символ)
//   "AORUS" (5) + тело (16) разбитое на 4 группы по 4 символа.
//
// Тело 16 символов:
//   [0-1]  tier   2 ASCII: "PR"=Pro / "BT"=Beta / "LT"=Lifetime
//   [2-9]  exp    8 HEX:   unix timestamp (hex, big-endian), "00000000"=бессрочно
//   [10-11] uid   2 HEX:   случайный идентификатор генерации (256 вариантов)
//   [12-15] hmac  4 BASE36: HMAC-SHA256(tier+exp+uid, secret)[0:3] в base36, 4 знака
//
// Пример: AORUS-PR68-3900-00A3-F12Z
// Проверка HMAC полностью офлайн — никакого сервера не нужно.
// Генератор: tools/generate_code.py (запускать локально, не в CI)
final class AorusCodeManager {
    static let shared = AorusCodeManager()
    private init() { load() }

    // MARK: - Tier

    enum Tier: String, Codable {
        case beta     = "beta"
        case pro      = "pro"
        case lifetime = "lifetime"

        var displayName: String {
            switch self { case .beta: return "Beta"; case .pro: return "Pro"; case .lifetime: return "Lifetime" }
        }
        var emoji: String {
            switch self { case .beta: return "🧪"; case .pro: return "⚡️"; case .lifetime: return "♾️" }
        }
    }

    // MARK: - Model

    struct ActivatedCode: Codable {
        let code: String
        let tier: Tier
        let expiresAt: Date?
        let activatedAt: Date
        let deviceId: String

        var isExpired: Bool { expiresAt.map { Date() > $0 } ?? false }
        var isValid: Bool { !isExpired }
    }

    // MARK: - State

    private(set) var activated: ActivatedCode?
    var isActivated: Bool { activated?.isValid == true }
    var currentTier: Tier? { isActivated ? activated?.tier : nil }

    // MARK: - Activate

    enum ActivationResult {
        case success(ActivatedCode)
        case invalidFormat
        case invalidCode
        case expired
        case alreadyActivated
    }

    func activate(code rawCode: String) -> ActivationResult {
        let code = rawCode.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip dashes → must be exactly 21 chars (AORUS + 16 body)
        let stripped = code.replacingOccurrences(of: "-", with: "")
        guard stripped.hasPrefix("AORUS"), stripped.count == 21 else {
            return .invalidFormat
        }
        if let existing = activated, existing.isValid, existing.code == code {
            return .alreadyActivated
        }
        guard let parsed = validateHMAC(stripped: stripped) else {
            return .invalidCode
        }
        if let exp = parsed.expiresAt, Date() > exp {
            return .expired
        }
        let record = ActivatedCode(
            code: code, tier: parsed.tier, expiresAt: parsed.expiresAt,
            activatedAt: Date(), deviceId: deviceID()
        )
        activated = record
        save(record)
        return .success(record)
    }

    func deactivate() {
        activated = nil
        AorusKeychain.delete(account: "aorus_code_v1")
    }

    // MARK: - HMAC validation

    // Secret XOR-обфусцирован чтобы не торчал голым в бинарнике.
    // Те же константы ДОЛЖНЫ быть в tools/generate_code.py.
    private static let secretXOR: [UInt8] = [
        0x41,0x4F,0x52,0x55,0x53,0x47,0x52,0x41,
        0x4D,0x5F,0x53,0x45,0x43,0x52,0x45,0x54,
        0x5F,0x4B,0x45,0x59,0x5F,0x56,0x31,0x5F,
        0x32,0x30,0x32,0x35,0x5F,0x41,0x4F,0x52,
    ]
    private static let xorMask: [UInt8] = [
        0x1A,0x2B,0x3C,0x4D,0x5E,0x6F,0x7A,0x1B,
        0x2C,0x3D,0x4E,0x5F,0x60,0x71,0x82,0x13,
        0x24,0x35,0x46,0x57,0x68,0x79,0x8A,0x1B,
        0x2C,0x3D,0x4E,0x5F,0x60,0x71,0x82,0x93,
    ]

    private func hmacSecret() -> SymmetricKey {
        SymmetricKey(data: Data(zip(Self.secretXOR, Self.xorMask).map { $0 ^ $1 }))
    }

    private struct Parsed { let tier: Tier; let expiresAt: Date? }

    // Body layout (16 chars after "AORUS"):
    //   [0-1]  tier   2 chars
    //   [2-9]  exp    8 hex chars  (unix ts in hex, "00000000" = never)
    //   [10-11] uid   2 hex chars
    //   [12-15] hmac  4 base36 chars
    private func validateHMAC(stripped: String) -> Parsed? {
        let body = String(stripped.dropFirst(5))   // 16 chars
        guard body.count == 16 else { return nil }

        let tierStr  = String(body.prefix(2))
        let expStr   = String(body.dropFirst(2).prefix(8))
        let uidStr   = String(body.dropFirst(10).prefix(2))
        let hmacStr  = String(body.dropFirst(12).prefix(4)).lowercased()

        // Verify HMAC
        let payload = Data((tierStr + expStr + uidStr).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: hmacSecret())
        let macBytes = Array(mac)
        // First 3 bytes → integer → base36, take first 4 chars
        let macInt = UInt32(macBytes[0]) << 16 | UInt32(macBytes[1]) << 8 | UInt32(macBytes[2])
        let computed = base36(macInt).prefix(4)
        guard computed == hmacStr else { return nil }

        // Decode tier
        let tier: Tier
        switch tierStr {
        case "PR": tier = .pro
        case "BT": tier = .beta
        case "LT": tier = .lifetime
        default:   return nil
        }

        // Decode expiry
        let expiresAt: Date?
        if expStr == "00000000" {
            expiresAt = nil
        } else if let ts = UInt32(expStr, radix: 16) {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(ts))
        } else {
            return nil
        }

        return Parsed(tier: tier, expiresAt: expiresAt)
    }

    // MARK: - Persistence

    private func save(_ code: ActivatedCode) {
        guard let data = try? JSONEncoder().encode(code) else { return }
        AorusKeychain.write(data, account: "aorus_code_v1")
    }

    private func load() {
        guard let data = AorusKeychain.read(account: "aorus_code_v1"),
              let code = try? JSONDecoder().decode(ActivatedCode.self, from: data),
              code.deviceId == deviceID() else { return }
        activated = code
    }

    // MARK: - Helpers

    private func deviceID() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }

    private func base36(_ value: UInt32) -> String {
        var v = value
        let alpha = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var result = ""
        repeat { result = String(alpha[Int(v % 36)]) + result; v /= 36 } while v > 0
        return result
    }
}

// MARK: - Shared Keychain helper

enum AorusKeychain {
    private static let service = "com.aorusgram"

    static func write(_ data: Data, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String]      = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var ref: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess else { return nil }
        return ref as? Data
    }

    static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
