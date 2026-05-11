import Foundation

// In-message translation. Uses Apple Translation framework (iOS 17.4+) when available,
// falls back to a lightweight cloud-free approach via the MLKit-free path, and as a last
// resort uses the free DeepL endpoint if the user provides an API key.
@available(iOS 17.4, *)
import Translation

final class TranslatorManager {
    static let shared = TranslatorManager()
    private init() {}

    private var cache: [String: String] = [:]
    private let cacheQueue = DispatchQueue(label: "aorusgram.translate.cache")

    // User-configured target language (default = device language)
    var targetLanguageCode: String = Locale.current.language.languageCode?.identifier ?? "ru"

    // Optional DeepL key (stored in Keychain)
    var deepLApiKey: String? {
        get { KeychainString.read(account: "deepl_key") }
        set { KeychainString.write(newValue ?? "", account: "deepl_key") }
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

        // iOS 17.4+ — use Apple Translation (on-device, privacy-safe)
        if #available(iOS 17.4, *) {
            translateApple(text: text, from: sourceLang, key: key, completion: completion)
        } else if let apiKey = deepLApiKey, !apiKey.isEmpty {
            translateDeepL(text: text, from: sourceLang, apiKey: apiKey, key: key, completion: completion)
        } else {
            completion(.failure(.noProvider))
        }
    }

    // MARK: - Apple Translation (iOS 17.4+)

    @available(iOS 17.4, *)
    private func translateApple(
        text: String, from sourceLang: String?, key: String,
        completion: @escaping (Result<String, TranslationError>) -> Void
    ) {
        Task {
            do {
                let source = sourceLang.flatMap { Locale.Language(identifier: $0) }
                let target = Locale.Language(identifier: targetLanguageCode)
                let session = TranslationSession.Configuration(source: source, target: target)
                // TranslationSession must be created on the main actor in a SwiftUI context.
                // Here we post a notification that the UI layer picks up to show the translation UI.
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .aorusTranslationRequested,
                        object: nil,
                        userInfo: ["text": text, "key": key, "config": session]
                    )
                }
                // The actual result arrives via .aorusTranslationResult
            }
        }
    }

    // MARK: - DeepL fallback

    private func translateDeepL(
        text: String, from sourceLang: String?, apiKey: String, key: String,
        completion: @escaping (Result<String, TranslationError>) -> Void
    ) {
        var components = URLComponents(string: "https://api-free.deepl.com/v2/translate")!
        var items: [URLQueryItem] = [
            .init(name: "text", value: text),
            .init(name: "target_lang", value: targetLanguageCode.uppercased()),
            .init(name: "auth_key", value: apiKey),
        ]
        if let src = sourceLang {
            items.append(.init(name: "source_lang", value: src.uppercased()))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(.network(error.localizedDescription))) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let translations = json["translations"] as? [[String: String]],
                  let translated = translations.first?["text"] else {
                DispatchQueue.main.async { completion(.failure(.parse)) }
                return
            }
            self?.cacheQueue.async { self?.cache[key] = translated }
            DispatchQueue.main.async { completion(.success(translated)) }
        }.resume()
    }

    // Cache the result from the Apple Translation session (called by UI layer)
    func cacheResult(key: String, translated: String) {
        cacheQueue.async { self.cache[key] = translated }
    }
}

enum TranslationError: LocalizedError {
    case featureDisabled
    case noProvider
    case network(String)
    case parse

    var errorDescription: String? {
        switch self {
        case .featureDisabled: return "Переводчик отключён в настройках"
        case .noProvider:      return "Требуется iOS 17.4+ или ключ DeepL API"
        case .network(let m):  return m
        case .parse:           return "Ошибка парсинга ответа"
        }
    }
}

extension Notification.Name {
    static let aorusTranslationRequested = Notification.Name("aorusgram_translation_requested")
    static let aorusTranslationResult    = Notification.Name("aorusgram_translation_result")
}

// MARK: - Minimal Keychain helper for API keys

private enum KeychainString {
    static func read(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.aorusgram.translator",
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var ref: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.aorusgram.translator",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        if value.isEmpty { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
