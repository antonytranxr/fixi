import Foundation

@MainActor protocol SceneVoiceSpeechInput: AnyObject {
    /// A clean recognition-run end while its device session is still connected.
    var onRecognitionEnded: (() -> Void)? { get set }
    func start(onText: @escaping (String, Bool) -> Void, onFailure: @escaping (String) -> Void,
               onStatus: @escaping (String) -> Void, allowPermissionRequest: Bool) async throws
    func stop()
    func waitUntilStopped() async throws
}

extension SceneVoiceSpeechInput {
    var onRecognitionEnded: (() -> Void)? { get { nil } set {} }
}

/// A text address filter, not speaker recognition. Every native segment must
/// begin with the address; a standalone address never arms later conversation.
/// Match the complete name Fixi, allowing only case and separator differences.
enum MendSpeechAddress {
    static func content(in text: String) -> String? {
        guard let prefix = text.range(of: "^\\s*hey[\\s,.:;!?–—-]+fixi(?:[\\s,.:;!?–—-]+|$)", options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


/// Text-only echo rejection, not speaker identification. Keep novel questions
/// even when they share vocabulary with the instruction being read aloud.
struct NarrationInterruptionGate {
    private let narration: [String]
    private var observedEcho: [String] = []
    private var promotedEchoPrefix: [String]?

    init(narration: String) { self.narration = Self.words(narration).map(\.value) }

    mutating func question(from text: String, final: Bool) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Self.words(clean), values = words.map(\.value)
        guard values.contains(where: { !["um", "uh", "hmm", "ah", "er"].contains($0) }) else { return nil }
        if let prefix = promotedEchoPrefix {
            return Self.removing(prefix: prefix, from: clean, words: words)
        }
        if Self.contains(values, in: narration) {
            // A final transcription finishes its segment; the next segment is
            // independent and must not inherit that segment's echoed prefix.
            observedEcho = final ? [] : values
            return nil
        }
        let prefix = observedEcho.count >= 3 && values.starts(with: observedEcho) ? observedEcho : []
        promotedEchoPrefix = prefix
        return Self.removing(prefix: prefix, from: clean, words: words)
    }

    private static func contains(_ phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= words.count else { return false }
        return (0...(words.count - phrase.count)).contains { index in
            words[index..<(index + phrase.count)].elementsEqual(phrase)
        }
    }
    private static func removing(prefix: [String], from text: String,
                                 words: [(value: String, range: Range<String.Index>)]) -> String? {
        guard !prefix.isEmpty, words.map(\.value).starts(with: prefix) else { return text }
        guard words.count > prefix.count else { return nil }
        return String(text[words[prefix.count].range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func words(_ text: String) -> [(value: String, range: Range<String.Index>)] {
        guard let pattern = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)?") else { return [] }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = String(text[range]).replacingOccurrences(of: "’", with: "'")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return (value, range)
        }
    }
}
