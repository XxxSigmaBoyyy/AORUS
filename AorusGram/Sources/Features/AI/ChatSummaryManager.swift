import Foundation
import NaturalLanguage

// Summarises a list of chat messages into a compact digest.
// Uses NLTagger for sentence segmentation and extractive summarisation
// (no network required, 100% on-device). For very long chats the algorithm
// picks the most "important" sentences by TF-IDF-like scoring.
final class ChatSummaryManager {
    static let shared = ChatSummaryManager()
    private init() {}

    struct ChatMessage {
        let senderName: String
        let text: String
        let date: Date
    }

    enum SummaryError: LocalizedError {
        case featureDisabled
        case tooFewMessages
        var errorDescription: String? {
            switch self {
            case .featureDisabled:  return "AI Саммари отключено в настройках"
            case .tooFewMessages:   return "Слишком мало сообщений для саммари"
            }
        }
    }

    // MARK: - Summarise

    func summarise(
        messages: [ChatMessage],
        maxSentences: Int = 5,
        completion: @escaping (Result<String, SummaryError>) -> Void
    ) {
        guard AorusGramConfig.isEnabled(.chatSummary) else {
            completion(.failure(.featureDisabled)); return
        }
        guard messages.count >= 3 else {
            completion(.failure(.tooFewMessages)); return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.extractiveSummary(messages: messages, maxSentences: maxSentences)
            DispatchQueue.main.async { completion(.success(result)) }
        }
    }

    // MARK: - Extractive algorithm

    private func extractiveSummary(messages: [ChatMessage], maxSentences: Int) -> String {
        // Build a single corpus string and collect sentences with metadata
        var sentences: [(text: String, score: Double, sender: String)] = []

        for msg in messages {
            let tagger = NLTagger(tagSchemes: [.tokenType, .sentimentScore])
            tagger.string = msg.text
            tagger.enumerateTags(in: msg.text.startIndex..<msg.text.endIndex,
                                 unit: .sentence, scheme: .tokenType, options: []) { _, range in
                let sentence = String(msg.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard sentence.count > 10 else { return true }

                // Score = length bonus + sentiment magnitude
                var score = Double(sentence.count) / 200.0
                let (sentTag, _) = tagger.tag(at: range.lowerBound, unit: .paragraph, scheme: .sentimentScore)
                if let v = sentTag.flatMap({ Double($0.rawValue) }) { score += abs(v) }

                sentences.append((text: sentence, score: score, sender: msg.senderName))
                return true
            }
        }

        guard !sentences.isEmpty else {
            return messages.prefix(3).map { "\($0.senderName): \($0.text)" }.joined(separator: "\n")
        }

        // Pick top-N by score, preserving original order
        let topIndices = sentences
            .enumerated()
            .sorted { $0.element.score > $1.element.score }
            .prefix(maxSentences)
            .map { $0.offset }
            .sorted()

        let lines = topIndices.map { idx -> String in
            let s = sentences[idx]
            return "• \(s.sender): \(s.text)"
        }

        return lines.joined(separator: "\n")
    }
}
