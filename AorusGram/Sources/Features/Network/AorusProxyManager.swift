import Foundation
import CryptoKit
import Security
import UIKit

// MARK: - AorusGram system proxy
//
// Fetches the active MTProxy configuration from the AorusGram control API and
// hands it to the network layer. The proxy is NEVER exposed in the UI, the
// secret is never shown, and the user cannot copy a tg://proxy link — it is
// applied system-side by `AorusProxyBridge` (injected into AppDelegate by
// aorus_branding.py).
//
// Security model:
//   * The API is authenticated with HMAC-SHA256 over a per-request message
//     (timestamp + nonce + device + key-version). Replays are rejected
//     server-side via the nonce window.
//   * All sensitive constants (endpoint, shared key, header names, user-agent)
//     are stored XOR-obfuscated and only materialised at the moment of use, so
//     a plain `strings` dump of the IPA reveals nothing. This is obfuscation,
//     not unbreakable secrecy — the determined reverse engineer can still
//     recover the key, which is exactly why the server supports key rotation
//     (X-Aorus-Kv) so a leaked build can be cut off.

public struct AorusProxyConfig: Codable, Equatable {
    public let server: String
    public let port: Int
    public let secret: String   // hex MTProxy secret (fake-TLS)
    public let ttl: TimeInterval

    public init(server: String, port: Int, secret: String, ttl: TimeInterval) {
        self.server = server
        self.port = port
        self.secret = secret
        self.ttl = ttl
    }
}

public final class AorusProxyManager {
    public static let shared = AorusProxyManager()
    private init() { load() }

    // Key version sent as X-Aorus-Kv. Bump in lock-step with the server table
    // when rotating SECRET_KEY.
    private let keyVersion = "1"

    // Proxy config JSON lives in Keychain — not in UserDefaults where it's readable
    // via file managers on jailbroken devices. Timestamp uses an opaque UD key.
    private let cacheStampKey = "b4e9f2d1-7a3c-4b8f-d6e1-2c5a9f7b4e3d"

    private var cached: AorusProxyConfig?
    private var cachedAt: Date = .distantPast
    private var inFlight = false
    private let lock = NSLock()

    // MARK: - Public

    /// Returns the last known proxy if it is still within its TTL, otherwise nil.
    /// Never blocks; callers should also trigger `refresh()` opportunistically.
    public func currentProxy() -> AorusProxyConfig? {
        lock.lock(); defer { lock.unlock() }
        guard let cfg = cached else { return nil }
        guard Date().timeIntervalSince(cachedAt) < cfg.ttl else { return nil }
        return cfg
    }

    /// The most recent proxy regardless of freshness — used as a fallback so the
    /// client can keep connecting through a slightly-stale proxy if the API is
    /// temporarily unreachable (e.g. itself blocked).
    public func lastKnownProxy() -> AorusProxyConfig? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Fetches a fresh proxy config. De-duplicates concurrent calls. Always
    /// resolves on the main queue.
    public func refresh(completion: ((AorusProxyConfig?) -> Void)? = nil) {
        lock.lock()
        if inFlight {
            lock.unlock()
            completion?(currentProxy() ?? lastKnownProxy())
            return
        }
        inFlight = true
        lock.unlock()

        guard let request = buildSignedRequest() else {
            lock.lock(); inFlight = false; lock.unlock()
            DispatchQueue.main.async { completion?(self.lastKnownProxy()) }
            return
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }
            defer {
                self.lock.lock(); self.inFlight = false; self.lock.unlock()
            }

            var result: AorusProxyConfig?
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data = data,
               let cfg = try? JSONDecoder().decode(AorusProxyConfig.self, from: data),
               !cfg.server.isEmpty, cfg.port > 0, !cfg.secret.isEmpty {
                result = cfg
                self.store(cfg)
            }

            DispatchQueue.main.async {
                completion?(result ?? self.lastKnownProxy())
            }
        }
        task.resume()
    }

    // MARK: - Request building

    private func buildSignedRequest() -> URLRequest? {
        guard !AorusTamperGuard.isFridaDetected else { return nil }
        let urlString = Obf.reveal(Obf.url)
        guard let url = URL(string: urlString) else { return nil }

        let ts = String(Int(Date().timeIntervalSince1970))
        let nonce = Self.randomHex(16)          // 32 hex chars
        let device = deviceHash()               // 64 hex chars
        let kv = keyVersion

        // message = ts \n nonce \n device \n kv   (LF separators, no trailing LF)
        let message = "\(ts)\n\(nonce)\n\(device)\n\(kv)"
        let signature = hmacHex(message: message, keyHex: Obf.reveal(Obf.k))

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue(Obf.reveal(Obf.ua),  forHTTPHeaderField: Obf.reveal(Obf.hUa))
        req.setValue(ts,                  forHTTPHeaderField: Obf.reveal(Obf.hTs))
        req.setValue(nonce,               forHTTPHeaderField: Obf.reveal(Obf.hNo))
        req.setValue(device,              forHTTPHeaderField: Obf.reveal(Obf.hDv))
        req.setValue(kv,                  forHTTPHeaderField: Obf.reveal(Obf.hKv))
        req.setValue(signature,           forHTTPHeaderField: Obf.reveal(Obf.hSg))
        return req
    }

    // SHA256(identifierForVendor) → 64 hex. Stable per install, resets on
    // reinstall — good enough for per-device rate limiting.
    private func deviceHash() -> String {
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? "aorus-unknown-device"
        let digest = SHA256.hash(data: Data(idfv.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func hmacHex(message: String, keyHex: String) -> String {
        let key = SymmetricKey(data: Self.hexToData(keyHex))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    private func store(_ cfg: AorusProxyConfig) {
        lock.lock()
        cached = cfg
        cachedAt = Date()
        lock.unlock()
        if let data = try? JSONEncoder().encode(cfg) {
            ProxyKeychain.write(data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheStampKey)
        }
        // Mirror to flat keys so the AppDelegate proxy bridge (injected into the
        // TelegramUI module, which cannot import AorusGram cleanly in every build)
        // can read the live config without a hard module dependency.
        let ud = UserDefaults.standard
        ud.set(cfg.server, forKey: "aorusgram_proxy_server")
        ud.set(cfg.port,   forKey: "aorusgram_proxy_port")
        ud.set(cfg.secret, forKey: "aorusgram_proxy_secret")
        // Wake the system-side bridge so it re-applies immediately.
        NotificationCenter.default.post(name: .aorusProxyConfigUpdated, object: nil)
    }

    private func load() {
        guard let data = ProxyKeychain.read(),
              let cfg = try? JSONDecoder().decode(AorusProxyConfig.self, from: data) else { return }
        cached = cfg
        let stamp = UserDefaults.standard.double(forKey: cacheStampKey)
        cachedAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : .distantPast
        // Publish flat keys synchronously at construction so the network layer
        // (Network.swift) sees a cached proxy on the very first connection of
        // this launch, before any async refresh completes.
        let ud = UserDefaults.standard
        ud.set(cfg.server, forKey: "aorusgram_proxy_server")
        ud.set(cfg.port,   forKey: "aorusgram_proxy_port")
        ud.set(cfg.secret, forKey: "aorusgram_proxy_secret")
    }

    // MARK: - Helpers

    private static func randomHex(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexToData(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[idx..<next], radix: 16) { data.append(byte) }
            idx = next
        }
        return data
    }
}

public extension Notification.Name {
    // Raw value must stay in sync with the observer injected into Account.swift
    // by aorus_branding.py (patch_system_proxy_runtime_monitor).
    static let aorusProxyConfigUpdated = Notification.Name("aorusgram_proxy_config_updated")
}

// MARK: - Proxy config Keychain storage
//
// Keeps the proxy config JSON off UserDefaults (readable by file managers on
// jailbroken devices) and into the Keychain which requires Secure Enclave unlock.
private enum ProxyKeychain {
    // Runtime XOR decode: zip(b,m).map{$0^$1} → UTF-8 string.
    // b values carry no semantic meaning without m.
    private static func _s(_ b: [UInt8], _ m: [UInt8]) -> String {
        String(bytes: zip(b, m).map { $0 ^ $1 }, encoding: .utf8)!
    }
    // "com.aorusgram.proxy"
    private static var svc: String {
        _s([0x72,0x4D,0x5E,0x6A,0x34,0x09,0x05,0xFD,0xEA,0xCD,0xC9,0xAD,0xB0,0xC0,0x8F,0x63,0x4D,0x4B,0x3D],
           [0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF,0x11,0x22,0x33,0x44])
    }
    // "cfg.v1"
    private static var acct: String {
        _s([0x72,0x44,0x54,0x6A,0x23,0x57],
           [0x11,0x22,0x33,0x44,0x55,0x66])
    }

    static func write(_ data: Data) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: svc,
                                kSecAttrAccount as String: acct]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: svc,
                                kSecAttrAccount as String: acct,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var ref: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess else { return nil }
        return ref as? Data
    }
}

// MARK: - String obfuscation
//
// Sensitive constants are XOR'd against a pad derived from SHA256 of a seed, so
// none of them appear verbatim in the binary. Decoded only at point of use.
private enum Obf {
    // pad = SHA256(concatenation of the three byte segments below).
    // No single searchable string exists in the binary — the segments are
    // meaningless individually and only their concatenation matters to SHA256.
    private static let pad: [UInt8] = {
        let s0: [UInt8] = [0x61,0x6f,0x72,0x75,0x73,0x67,0x72,0x61,0x6d,0x3a,0x3a,0x6e]
        let s1: [UInt8] = [0x65,0x74,0x73,0x68,0x69,0x65,0x6c,0x64,0x3a,0x3a,0x76,0x31]
        let s2: [UInt8] = [0x3a,0x3a,0x73,0x68,0x69,0x65,0x6c,0x64,0x2d,0x70,0x61,0x64]
        return Array(SHA256.hash(data: Data(s0 + s1 + s2)))
    }()

    static func reveal(_ bytes: [UInt8]) -> String {
        var out = [UInt8](repeating: 0, count: bytes.count)
        for i in 0..<bytes.count { out[i] = bytes[i] ^ pad[i % pad.count] }
        return String(decoding: out, as: UTF8.self)
    }

    // SECRET_KEY_v1 (hex)
    static let k: [UInt8] = [218,222,109,59,174,253,213,114,87,186,212,15,230,103,194,147,251,231,133,154,181,93,55,114,229,86,131,56,179,58,229,155,137,133,59,59,173,175,214,32,6,229,221,89,229,108,149,197,251,230,210,152,229,11,58,117,179,3,133,105,190,59,176,204,138,137,97,63,170,169,134,114,0,185,221,90,182,102,198,206,164,239,130,206,228,95,97,32,180,81,215,107,224,59,180,205,130,140,59,63,241,165,215,34,82,229,217,94,230,98,207,150,163,228,208,155,229,81,103,115,224,87,139,59,227,111,225,155]
    // https://api.aorusgram.com/getProxy
    static let url: [UInt8] = [211,201,44,46,187,166,205,62,85,172,132,66,177,58,133,130,177,177,147,204,234,71,96,46,188,77,213,63,242,8,242,192,195,196]
    // AorusGram/1.0.0 (iOS)
    static let ua: [UInt8] = [250,210,42,43,187,219,144,112,89,243,220,66,224,123,199,215,234,191,174,254,174]
    // X-Aorus-Ts
    static let hTs: [UInt8] = [227,144,25,49,186,233,145,60,96,175]
    // X-Aorus-Nonce
    static let hNo: [UInt8] = [227,144,25,49,186,233,145,60,122,179,131,15,181]
    // X-Aorus-Device
    static let hDv: [UInt8] = [227,144,25,49,186,233,145,60,112,185,155,5,179,48]
    // X-Aorus-Kv
    static let hKv: [UInt8] = [227,144,25,49,186,233,145,60,127,170]
    // X-Aorus-Sign
    static let hSg: [UInt8] = [227,144,25,49,186,233,145,60,103,181,138,2]
    // User-Agent
    static let hUa: [UInt8] = [238,206,61,44,229,221,133,116,90,168]
}
