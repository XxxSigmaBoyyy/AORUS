import SwiftUI
import UIKit
#if canImport(Translation)
import Translation
#endif

// Standalone translator screen. Paste/type text, pick target language,
// tap Translate. Result appears below with copy button.
struct TranslatorView: View {
    @Environment(\.dismiss) var dismiss
    @State private var sourceText      = ""
    @State private var translatedText  = ""
    @State private var targetLang      = TranslatorManager.shared.targetLanguageCode
    @State private var sourceLang      = "auto"
    @State private var isTranslating   = false
    @State private var errorMessage    = ""
    @State private var showError       = false
    @FocusState private var inputFocused: Bool

    // iOS 17.4+ Apple Translation sheet support
    @State private var appleRequest: String = ""
    @State private var pendingKey: String = ""

    private let mgr = TranslatorManager.shared
    private let languages: [(code: String, name: String, flag: String)] = [
        ("auto","Автоопределение","🌐"),
        ("ru", "Русский",         "🇷🇺"),
        ("en", "English",         "🇬🇧"),
        ("es", "Español",         "🇪🇸"),
        ("fr", "Français",        "🇫🇷"),
        ("de", "Deutsch",         "🇩🇪"),
        ("it", "Italiano",        "🇮🇹"),
        ("pt", "Português",       "🇵🇹"),
        ("zh", "中文",             "🇨🇳"),
        ("ja", "日本語",            "🇯🇵"),
        ("ko", "한국어",            "🇰🇷"),
        ("ar", "العربية",          "🇸🇦"),
        ("tr", "Türkçe",          "🇹🇷"),
        ("uk", "Українська",      "🇺🇦"),
        ("pl", "Polski",          "🇵🇱"),
    ]

    var body: some View {
        NavigationView {
            ZStack {
                AorusAnimatedBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        // Language pickers
                        GlassCard {
                            HStack(spacing: 12) {
                                langPicker(title: "С", selection: $sourceLang)
                                Image(systemName: "arrow.right")
                                    .foregroundColor(Color(hex: "#FF6D00"))
                                    .font(.system(size: 16, weight: .bold))
                                langPicker(title: "На", selection: $targetLang)
                            }
                            .padding(14)
                        }

                        // Source text
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Исходный текст", systemImage: "text.bubble")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color(hex: "#5C6BC0"))

                                TextEditor(text: $sourceText)
                                    .focused($inputFocused)
                                    .font(.system(size: 15))
                                    .frame(minHeight: 120)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                                HStack {
                                    Text("\(sourceText.count) симв.")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    if !sourceText.isEmpty {
                                        Button {
                                            sourceText = ""
                                            translatedText = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Button {
                                        if let s = UIPasteboard.general.string {
                                            sourceText = s
                                        }
                                    } label: {
                                        Image(systemName: "doc.on.clipboard")
                                            .foregroundColor(Color(hex: "#FF6D00"))
                                    }
                                }
                            }
                            .padding(14)
                        }

                        // Translate button
                        GlassButton(
                            title: isTranslating ? "Перевожу..." : "Перевести",
                            icon:  "globe",
                            color: Color(hex: "#FF6D00")
                        ) {
                            translate()
                        }
                        .disabled(sourceText.isEmpty || isTranslating)

                        // Result
                        if !translatedText.isEmpty {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Label("Перевод", systemImage: "checkmark.seal.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.green)
                                        Spacer()
                                        Button {
                                            UIPasteboard.general.string = translatedText
                                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                                .foregroundColor(Color(hex: "#FF6D00"))
                                        }
                                    }
                                    Text(translatedText)
                                        .font(.system(size: 16))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                        .textSelection(.enabled)
                                }
                                .padding(14)
                            }
                            .transition(.opacity)
                        }

                        if showError {
                            Text(errorMessage)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .padding(.horizontal, 8)
                        }

                        Spacer(minLength: 30)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Переводчик")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .modifier(AppleTranslateModifier(
                pendingKey: $pendingKey,
                request: $appleRequest,
                target: targetLang
            ))
        }
    }

    private func langPicker(title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Menu {
                ForEach(languages, id: \.code) { lang in
                    Button {
                        selection.wrappedValue = lang.code
                    } label: {
                        Label("\(lang.flag) \(lang.name)", systemImage: selection.wrappedValue == lang.code ? "checkmark" : "")
                    }
                }
            } label: {
                HStack {
                    if let l = languages.first(where: { $0.code == selection.wrappedValue }) {
                        Text("\(l.flag) \(l.name)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func translate() {
        inputFocused = false
        isTranslating = true
        showError = false
        let src: String? = (sourceLang == "auto") ? nil : sourceLang

        mgr.translate(text: sourceText, from: src, to: targetLang) { result in
            DispatchQueue.main.async {
                isTranslating = false
                switch result {
                case .success(let text):
                    withAnimation { translatedText = text }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .failure(let err):
                    errorMessage = err.localizedDescription
                    showError = true
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }
}

// MARK: - Apple Translation sheet bridge (iOS 17.4+)

private struct AppleTranslateModifier: ViewModifier {
    @Binding var pendingKey: String
    @Binding var request: String
    let target: String
    @State private var observer: NSObjectProtocol?
    @State private var configuration: Any? // TranslationSession.Configuration — type erased pre-17.4

    func body(content: Content) -> some View {
#if canImport(Translation)
        if #available(iOS 17.4, *) {
            content
                .translationTask(configuration as? TranslationSession.Configuration) { session in
                    guard !request.isEmpty else { return }
                    do {
                        let response = try await session.translate(request)
                        NotificationCenter.default.post(
                            name: .aorusTranslationResult,
                            object: nil,
                            userInfo: ["key": pendingKey, "translated": response.targetText]
                        )
                        request = ""
                    } catch {
                        NotificationCenter.default.post(
                            name: .aorusTranslationResult,
                            object: nil,
                            userInfo: ["key": pendingKey, "translated": ""]
                        )
                    }
                }
                .onAppear {
                    observer = NotificationCenter.default.addObserver(
                        forName: .aorusTranslationRequested,
                        object: nil, queue: .main
                    ) { note in
                        guard let text = note.userInfo?["text"] as? String,
                              let key  = note.userInfo?["key"]  as? String else { return }
                        request = text
                        pendingKey = key
                        let cfg = TranslationSession.Configuration(
                            source: nil,
                            target: Locale.Language(identifier: target)
                        )
                        configuration = cfg
                    }
                }
                .onDisappear {
                    if let o = observer { NotificationCenter.default.removeObserver(o) }
                }
        } else {
            content
        }
#else
        content
#endif
    }
}
