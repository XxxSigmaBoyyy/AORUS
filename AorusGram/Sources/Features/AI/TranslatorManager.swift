import Foundation
import Security

// In-message translation. Uses Apple Translation framework (iOS 17.4+) when available,
// falls back to DeepL free API if the user provides an API key.
// `#if canImport(Translation)` guards the iOS 17.4-only import correctly.
#if canImport(Translation)
import Translation
#endif

final class TranslatorManager {
    static let shared = TranslatorManager()
    private init() {}

    private var cache: [String: String] = [:]
    private let cacheQueue = DispatchQueue(label: "aorusgram.translate.cache")

    var targetLanguageCode: String = Locale.current.languageCode ?? "ru"

    var deepLApiKey: String? {
        get { TranslatorKeychain.read(account: "deepl_key") }
        set { TranslatorKeychain.write(newValue ?? "", account: "deepl_key") }
    }

    // MARK: - Translate

    func translate(
        text: String,
        from sourceLang: String? = nil,
        completion: @escaping (Result<String, TranslationError>) -> Void
    ) {
        guard AorusGramConfig.isEnabled(.translator) else {
            completion(.failure(.featureDisabled)); return
        }
        let key = "\(sourceLang ?? "auto")|\(targetLanguageCode)|\(text)"
        if let cached = cacheQueue.sync(execute: { cache[key] }) {
            completion(.success(cached)); return
        }

#if canImport(Translation)
        if #available(iOS 17.4, *) {
            translateApple(text: text, from: sourceLang, key: key, completion: completion)
            return
        }
#endif
        if let apiKey = deepLApiKey, !apiKey.isEmpty {
            translateDeepL(text: text, from: sourceLang, apiKey: apiKey, key: key, completion: completion)
        } else {
            completion(.failure(.noProvider))
        }
    }

    // MARK: - Apple Translation (iOS 17.4+)

#if canImport(Translation)
    @available(iOS 17.4, *)
    private func translateApple(
        text: String, from sourceLang: String?, key: String,
        completion: @escaping (Result<String, TranslationError>) -> Void
    ) {
        // TranslationSession must be presented via SwiftUI overlay.
        // We post a notification; the active chat VC picks it up, shows the sheet,
        // then posts .aorusTranslationResult with the translated string.
        let userInfo: [String: Any] = [
            "text":   text,
            "key":    key,
            "source": sourceLang ?? "",
            "target": targetLanguageCode,
        ]
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .aorusTranslationRequested,
                object: nil,
                userInfo: userInfo
            )
        }
        // Register a one-shot observer for the result
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: .aorusTranslationResult,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let rKey = note.userInfo?["key"] as? String, rKey == key,
                  let translated = note.userInfo?["translated"] as? String else { return }
            if let t = token { NotificationCenter.default.removeObserver(t) }
            self?.cacheQueue.async { self?.cache[key] = translated }
            completion(.success(translated))
        }
    }
#endif

    // MARK: - DeepL fallback

    private func translateDeepL(
        text: String, from sourceLang: String?, apiKey: String, key: String,
        completion: @escaping (Result<String, TranslationError>) -> Void
    ) {
        guard var comps = URLComponents(string: "https://api-free.deepl.com/v2/translate") else {
            completion(.failure(.parse)); return
        }
        var items: [URLQueryItem] = [
            .init(name: "text",        value: text),
            .init(name: "target_lang", value: targetLanguageCode.uppercased()),
            .init(name: "auth_key",    value: apiKey),
        ]
        if let src = sourceLang { items.append(.init(name: "source_lang", value: src.uppercased())) }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            if let error { DispatchQueue.main.async { completion(.failure(.network(error.localizedDescription))) }; return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let translations = json["translations"] as? [[String: String]],
                  let translated = translations.first?["text"] else {
                DispatchQueue.main.async { completion(.failure(.parse)) }; return
            }
            self?.cacheQueue.async { self?.cache[key] = translated }
            DispatchQueue.main.async { completion(.success(translated)) }
        }.resume()
    }

    func cacheResult(key: String, translated: String) {
        cacheQueue.async { self.cache[key] = translated }
    }
}

// MARK: - Error

enum TranslationError: LocalizedError {
    case featureDisabled, noProvider, network(String), parse
    var errorDescription: String? {
        switch self {
        case .featureDisabled: return "Переводчик отключён в настройках"
        case .noProvider:      return "Требуется iOS 17.4+ или ключ DeepL API"
        case .network(let m):  return m
        case .parse:           return "Ошибка парсинга ответа"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let aorusTranslationRequested = Notification.Name("aorusgram_translation_requested")
    static let aorusTranslationResult    = Notification.Name("aorusgram_translation_result")
}

// MARK: - Keychain helper

private enum TranslatorKeychain {
    static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "com.aorusgram.translator",
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var ref: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "com.aorusgram.translator",
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
