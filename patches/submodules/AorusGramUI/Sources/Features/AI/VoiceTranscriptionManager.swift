import Foundation
import Speech
import AVFoundation

// Transcribes Telegram voice messages using Apple's on-device Speech framework.
// Call transcribe(fileURL:locale:completion:) with the local path of the .ogg/.m4a file.
// Result is cached by file URL so replays are instant.
final class VoiceTranscriptionManager {
    static let shared = VoiceTranscriptionManager()
    private init() {}

    private var cache: [URL: String] = [:]
    private let queue = DispatchQueue(label: "aorusgram.transcription", qos: .userInitiated)

    // MARK: - Permission

    var authStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    // MARK: - Transcription

    func transcribe(
        fileURL: URL,
        locale: Locale = Locale.current,
        completion: @escaping (Result<String, TranscriptionError>) -> Void
    ) {
        guard AorusGramConfig.isEnabled(.voiceTranscription) else {
            completion(.failure(.featureDisabled))
            return
        }
        // Return cached result immediately
        if let cached = cache[fileURL] {
            completion(.success(cached))
            return
        }
        guard authStatus == .authorized else {
            requestPermission { granted in
                if granted {
                    self.transcribe(fileURL: fileURL, locale: locale, completion: completion)
                } else {
                    completion(.failure(.notAuthorized))
                }
            }
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "ru-RU")),
              recognizer.isAvailable else {
            completion(.failure(.recognizerUnavailable))
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        // Prefer on-device recognition (privacy + no network cost)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error {
                DispatchQueue.main.async {
                    completion(.failure(.recognition(error.localizedDescription)))
                }
                return
            }
            guard let result, result.isFinal else { return }
            let text = result.bestTranscription.formattedString
            self?.queue.async { self?.cache[fileURL] = text }
            DispatchQueue.main.async { completion(.success(text)) }
        }
    }

    // MARK: - Supported locales

    static var availableLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .sorted { $0.identifier < $1.identifier }
    }
}

enum TranscriptionError: LocalizedError {
    case featureDisabled
    case notAuthorized
    case recognizerUnavailable
    case recognition(String)

    var errorDescription: String? {
        switch self {
        case .featureDisabled:        return "Транскрипция отключена в настройках"
        case .notAuthorized:          return "Нет разрешения на распознавание речи"
        case .recognizerUnavailable:  return "Распознаватель недоступен для данного языка"
        case .recognition(let msg):   return msg
        }
    }
}
