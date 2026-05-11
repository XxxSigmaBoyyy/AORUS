import Foundation
import Security
import LocalAuthentication

// Dual-PIN system: real PIN shows the normal account, decoy PIN shows a
// preset "empty" profile. PINs are stored in the device Keychain (kSecClassGenericPassword).
// Integration hook is in aorus_branding.py — the passcode entry controller calls
//   SecretPinManager.shared.evaluate(pin:) which returns the action to take.
final class SecretPinManager {
    static let shared = SecretPinManager()
    private init() {}

    private let service = "com.aorusgram.secretpin"

    enum PinResult {
        case realAccount
        case decoyAccount
        case incorrect
    }

    // MARK: - Load / configure

    func load() {
        // nothing to restore — Keychain is persistent across launches
    }

    var isConfigured: Bool {
        return readPin(account: "real") != nil
    }

    // MARK: - Store / clear

    func setRealPin(_ pin: String) throws {
        try writePin(pin, account: "real")
    }

    func setDecoyPin(_ pin: String) throws {
        try writePin(pin, account: "decoy")
    }

    func clearPins() {
        deletePin(account: "real")
        deletePin(account: "decoy")
        AorusGramConfig.setEnabled(.secretPin, false)
    }

    // MARK: - Evaluate

    func evaluate(pin: String) -> PinResult {
        guard let real = readPin(account: "real") else { return .incorrect }
        if pin == real { return .realAccount }
        if let decoy = readPin(account: "decoy"), pin == decoy { return .decoyAccount }
        return .incorrect
    }

    // MARK: - Keychain helpers

    private func writePin(_ pin: String, account: String) throws {
        let data = Data(pin.utf8)
        // Delete existing entry first
        deletePin(account: account)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   data,
            // Not accessible when device is locked — intentional for security
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw SecretPinError.keychainWrite(status)
        }
    }

    private func readPin(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deletePin(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum SecretPinError: LocalizedError {
    case keychainWrite(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainWrite(let status):
            return "Keychain error: \(status)"
        }
    }
}
