import SwiftUI
import UIKit
import AVFoundation
import Speech
import UniformTypeIdentifiers

// Standalone voice transcriber. Two modes:
//   1. Record from microphone — live transcription via SFSpeechRecognizer.
//   2. Pick an audio file (.m4a/.wav/.mp3/.ogg) — offline transcription.
struct VoiceTranscriberView: View {
    @Environment(\.dismiss) var dismiss

    @State private var transcribedText = ""
    @State private var isRecording     = false
    @State private var isTranscribing  = false
    @State private var errorMessage    = ""
    @State private var showError       = false
    @State private var selectedLocale  = Locale.current.identifier
    @State private var showFilePicker  = false

    // Live recording
    @State private var audioEngine: AVAudioEngine?
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask:    SFSpeechRecognitionTask?

    private let mgr = VoiceTranscriptionManager.shared
    private let availableLocales: [(id: String, name: String, flag: String)] = [
        ("ru-RU", "Русский",     "🇷🇺"),
        ("en-US", "English (US)","🇺🇸"),
        ("en-GB", "English (UK)","🇬🇧"),
        ("es-ES", "Español",     "🇪🇸"),
        ("fr-FR", "Français",    "🇫🇷"),
        ("de-DE", "Deutsch",     "🇩🇪"),
        ("it-IT", "Italiano",    "🇮🇹"),
        ("pt-BR", "Português",   "🇧🇷"),
        ("zh-CN", "中文",         "🇨🇳"),
        ("ja-JP", "日本語",        "🇯🇵"),
        ("ko-KR", "한국어",        "🇰🇷"),
        ("uk-UA", "Українська",  "🇺🇦"),
        ("pl-PL", "Polski",      "🇵🇱"),
        ("tr-TR", "Türkçe",      "🇹🇷"),
        ("ar-SA", "العربية",      "🇸🇦"),
    ]

    var body: some View {
        NavigationView {
            ZStack {
                AorusAnimatedBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        // Language picker
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Язык распознавания", systemImage: "globe")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(hex: "#5C6BC0"))
                                Menu {
                                    ForEach(availableLocales, id: \.id) { l in
                                        Button { selectedLocale = l.id } label: {
                                            Label("\(l.flag) \(l.name)", systemImage: selectedLocale == l.id ? "checkmark" : "")
                                        }
                                    }
                                } label: {
                                    HStack {
                                        if let l = availableLocales.first(where: { $0.id == selectedLocale }) {
                                            Text("\(l.flag)  \(l.name)")
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundColor(.primary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.down").foregroundColor(.secondary)
                                    }
                                    .padding(10)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            .padding(14)
                        }

                        // Microphone record card
                        GlassCard {
                            VStack(spacing: 12) {
                                Image(systemName: isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                                    .font(.system(size: 56))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: isRecording ? [.red, .pink] : [Color(hex: "#FF6D00"), Color(hex: "#FF3D00")],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        )
                                    )
                                    .symbolEffect(.pulse, isActive: isRecording)
                                Text(isRecording ? "Запись... Говорите" : "Нажмите чтобы записать")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.secondary)
                                Button {
                                    isRecording ? stopRecording() : startRecording()
                                } label: {
                                    Text(isRecording ? "Остановить" : "Записать")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 30).padding(.vertical, 10)
                                        .background(
                                            LinearGradient(
                                                colors: isRecording ? [.red, .pink] : [Color(hex: "#FF6D00"), Color(hex: "#FF3D00")],
                                                startPoint: .leading, endPoint: .trailing
                                            ),
                                            in: Capsule()
                                        )
                                }
                            }
                            .padding(20)
                        }

                        // OR file picker
                        GlassButton(
                            title: "Выбрать аудио файл",
                            icon:  "doc.fill",
                            color: Color(hex: "#5C6BC0")
                        ) {
                            showFilePicker = true
                        }
                        .disabled(isRecording || isTranscribing)

                        // Result
                        if !transcribedText.isEmpty {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Label("Транскрипция", systemImage: "text.bubble.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.green)
                                        Spacer()
                                        Button {
                                            UIPasteboard.general.string = transcribedText
                                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                                .foregroundColor(Color(hex: "#FF6D00"))
                                        }
                                    }
                                    Text(transcribedText)
                                        .font(.system(size: 15))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                        .textSelection(.enabled)
                                }
                                .padding(14)
                            }
                        }

                        if isTranscribing {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Распознавание...")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
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
            .navigationTitle("Транскриптор")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") {
                        if isRecording { stopRecording() }
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.audio, UTType("public.mp3") ?? .data, UTType("public.audio") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                handleFilePick(result)
            }
        }
    }

    // MARK: - Live recording

    private func startRecording() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    errorMessage = "Нет разрешения на распознавание речи. Включите в Настройках."
                    showError = true
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            errorMessage = "Нет разрешения на микрофон"
                            showError = true
                            return
                        }
                        beginAudio()
                    }
                }
            }
        }
    }

    private func beginAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Не удалось активировать аудиосессию: \(error.localizedDescription)"
            showError = true
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let locale = Locale(identifier: selectedLocale)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            errorMessage = "Распознаватель для языка \(selectedLocale) недоступен"
            showError = true
            return
        }
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result = result {
                DispatchQueue.main.async {
                    transcribedText = result.bestTranscription.formattedString
                }
            }
            if let error = error {
                DispatchQueue.main.async {
                    if !error.localizedDescription.lowercased().contains("cancel") {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
            recognitionRequest = request
            recognitionTask = task
            isRecording = true
            showError = false
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            errorMessage = "Не удалось запустить запись: \(error.localizedDescription)"
            showError = true
        }
    }

    private func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - File transcription

    private func handleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            transcribeFile(url: url)
        case .failure(let err):
            errorMessage = err.localizedDescription
            showError = true
        }
    }

    private func transcribeFile(url: URL) {
        // Some file pickers return a URL we need to start security-scoped access on
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        isTranscribing = true
        showError = false

        mgr.transcribe(fileURL: url, locale: Locale(identifier: selectedLocale)) { result in
            DispatchQueue.main.async {
                if needsScopedAccess { url.stopAccessingSecurityScopedResource() }
                isTranscribing = false
                switch result {
                case .success(let text):
                    transcribedText = text
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
