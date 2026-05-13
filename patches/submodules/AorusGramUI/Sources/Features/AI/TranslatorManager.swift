import Foundation
import Security

// Translator. Three providers, tried in order:
//   1. Apple Translation framework (iOS 17.4+) — on-device, free, best quality.
//   2. MyMemory free public API — no key required, 5000 chars/day per IP.
//   3. DeepL — only if the user provides an API key in TranslatorKeychain.
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
        to targetLang: String? = nil,
        completion: @escaping (Result<String, TranslationError>) -> Void
    ) {
        let target = targetLang ?? targetLanguageCode
        let key = "\(sourceLang ?? "auto")|\(target)|\(text)"
        if let cached = cacheQueue.sync(execute: { cache[key] }) {
            completion(.success(cached)); return
        }

#if canImport(Translation)
        if #available(iOS 17.4, *) {
            translateApple(text: text, from: sourceLang, target: target, key: key) { [weak self] result in
                if case .success = result { completion(result); return }
                // Apple Translation failed (no model downloaded etc.) → fall through to MyMemory
                self?.translateMyMemory(text: text, from: sourceLang, target: target, key: key, completion: completion)
            }
            return
        }
#endif
        // Try DeepL first if a key is configured, otherwise MyMemory.
        if let apiKey = deepLApiKey, !apiKey.isEmpty {
            translateDeepL(text: text, from: sourceLang, target: target, apiKey: apiKey, key: key, completion: completion)
        } else {
            translateMyMemory(text: text, from: sourceLang, target: target, key: key, completion: completion)
        }
    }

    // MARK: - Apple Translation (iOS 17.4+)

#if canImport(Translation)
    @available(iOS 17.4, *)
    private func translateApple(
        text: String, from sourceLang: String?, target: String, key: String,
        completion: @escaping (Result<String, TranslationError>) -> Void
    ) {
        let userInfo: [String: Any] = [
            "text":   text,
            "key":    key,
            "source": sourceLang ?? "",
            "target": target,
        ]
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .aorusTranslationRequested,
                object: nil, userInfo: userInfo
            )
        }
        // One-shot result observer with a 6s timeout fallback
        var token: NSObjectProtocol?
        let timeoutWork = DispatchWorkItem {
            if let t = token { NotificationCenter.default.removeObserver(t); token = nil }
            completion(.failure(.network("Apple Translation timeout")))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeoutWork)
        token = NotificationCenter.default.addObserver(
            forName: .aorusTranslationResult,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let rKey = note.userInfo?["key"] as? String, rKey == key,
                  let translated = note.userInfo?["translated"] as? String else { return }
            if let t = token { NotificationCenter.default.removeObserver(t); token = nil }
            timeoutWork.cancel()
            self?.cacheQueue.async { self?.cache[key] = translated }
            completion(.success(translated))
        }
    }
#endif

    // MARK: - MyMemory free API (no key needed)

    private func translateMyMemory(
        text: String, from sourceLang: String?, target: String, key: String,
        completion: @escaping (Result<String, TranslationError>) -> Void
    ) {
        // MyMemory expects "en|ru" — source MUST be specified; "auto" is not supported,
        // so we default to English on unknown source.
        let source = (sourceLang?.isEmpty == false ? sourceLang! : "en")
        let pair = "\(source.lowercased())|\(target.lowercased())"
        guard var comps = URLComponents(string: "https://api.mymemory.translated.net/get") else {
            completion(.failure(.parse)); return
        }
        comps.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: pair),
            URLQueryItem(name: "de", value: "aorusgram@telegra.ph"), // increases daily quota
        ]
        guard let url = comps.url else { completion(.failure(.parse)); return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(.network(error.localizedDescription))) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseData = json["responseData"] as? [String: Any],
                  let translated = responseData["translatedText"] as? String else {
                DispatchQueue.main.async { completion(.failure(.parse)) }
                return
            }
            // MyMemory uses HTML entities — decode them.
            let decoded = translated
                .replacingOccurrences(of: "&#39;",  with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;",  with: "&")
                .replacingOccurrences(of: "&lt;",   with: "<")
                .replacingOccurrences(of: "&gt;",   with: ">")
            self?.cacheQueue.async { self?.cache[key] = decoded }
            DispatchQueue.main.async { completion(.success(decoded)) }
        }.resume()
    }

    // MARK: - DeepL premium fallback

    private func translateDeepL(
        text: String, from sourceLang: String?, target: String, apiKey: String, key: String,
        completion: @escaping (Result<String, TranslationError>) -> Void
    ) {
        guard var comps = URLComponents(string: "https://api-free.deepl.com/v2/translate") else {
            completion(.failure(.parse)); return
        }
        var items: [URLQueryItem] = [
            .init(name: "text",        value: text),
            .init(name: "target_lang", value: target.uppercased()),
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

    // MARK: - Detect language (simple heuristic)

    static func detectLanguage(of text: String) -> String {
        // Cyrillic ratio → Russian
        let cyrillic = text.unicodeScalars.filter { $0.value >= 0x0400 && $0.value <= 0x04FF }.count
        if Double(cyrillic) / max(1.0, Double(text.count)) > 0.3 { return "ru" }
        // CJK ratio → Chinese (rough)
        let cjk = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        if cjk > 0 { return "zh" }
        // Default to English
        return "en"
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
