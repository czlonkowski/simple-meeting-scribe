import Foundation

/// One decoded Parakeet token with its timing. `text` already has the
/// SentencePiece word marker turned into a leading space, so concatenating
/// tokens reproduces the transcript.
struct ParakeetToken: Hashable {
    let text: String
    let start: Double
    let end: Double
}

/// Turns Parakeet's flat token stream into transcript-sized segments.
/// Whisper hands the pipeline ~≤15 s segments; the merger and the speaker
/// mapping were tuned for that shape, so Parakeet output is cut the same way.
enum ParakeetSegmenter {
    /// Silence between tokens that starts a new segment.
    static let gapThreshold: Double = 0.8
    /// Longest segment emitted when no punctuation or gap offers a cut.
    static let maxDuration: Double = 15.0

    private static let sentenceEnders: Set<Character> = [".", "?", "!", "…"]

    static func segments(from tokens: [ParakeetToken]) -> [WhisperSegment] {
        var out: [WhisperSegment] = []
        var current: [ParakeetToken] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                out.append(WhisperSegment(start: first.start, end: last.end, text: text))
            }
            current.removeAll()
        }

        for token in tokens {
            if let last = current.last {
                let gap = token.start - last.end
                let wouldExceed = token.end - current[0].start > maxDuration
                if gap > gapThreshold || wouldExceed { flush() }
            }
            current.append(token)
            if let lastChar = token.text.last, sentenceEnders.contains(lastChar) {
                flush()
            }
        }
        flush()
        return out
    }
}
