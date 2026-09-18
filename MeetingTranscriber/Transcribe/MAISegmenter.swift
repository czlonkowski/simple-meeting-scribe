import Foundation

/// One MAI-Transcribe speaker turn from the fast-transcription response's
/// `phrases` array. `speaker` is present only when diarization was requested;
/// `words` only when word timestamps were.
struct MAIPhrase: Decodable, Equatable {
    struct Word: Decodable, Equatable {
        let text: String
        let offsetMilliseconds: Double
        let durationMilliseconds: Double
    }
    let speaker: Int?
    let offsetMilliseconds: Double
    let durationMilliseconds: Double
    let text: String
    let words: [Word]?
}

/// A transcript-sized piece of MAI output. `speaker` is MAI's raw
/// diarization id, nil when diarization was off.
struct MAISpan: Hashable {
    let start: Double
    let end: Double
    let text: String
    let speaker: Int?
}

/// Pure helpers between MAI-Transcribe responses and the app's segment
/// shapes, kept apart from the network code so they can be unit-tested.
enum MAISegmenter {

    /// Group word timings into sentence-ish spans, flushing on speaker change,
    /// sentence-ending punctuation, or a 400-character / 30 s cap — the same
    /// shape `ScribeEngine` produces. `offset` (seconds) shifts every time,
    /// for chunks cut out of a longer recording.
    static func spans(from phrases: [MAIPhrase], offset: Double = 0) -> [MAISpan] {
        var spans: [MAISpan] = []
        var words: [String] = []
        var characters = 0
        var start: Double?
        var end: Double = 0
        var speaker: Int?

        func flush() {
            if let start, !words.isEmpty {
                spans.append(MAISpan(start: start + offset, end: end + offset,
                                     text: words.joined(separator: " "), speaker: speaker))
            }
            words = []
            characters = 0
            start = nil
        }

        for phrase in phrases {
            if phrase.speaker != speaker { flush() }
            speaker = phrase.speaker

            guard let timed = phrase.words, !timed.isEmpty else {
                // No word timings: the phrase is the smallest unit we have.
                flush()
                let text = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    start = phrase.offsetMilliseconds / 1000
                    end = (phrase.offsetMilliseconds + phrase.durationMilliseconds) / 1000
                    words = [text]
                }
                flush()
                continue
            }

            for word in timed {
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let wordStart = word.offsetMilliseconds / 1000
                if start == nil { start = wordStart }
                words.append(text)
                characters += text.count + 1
                end = wordStart + word.durationMilliseconds / 1000

                let sentenceEnd = text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?")
                let tooLong = characters > 400 || end - (start ?? end) > 30
                if sentenceEnd || tooLong { flush() }
            }
        }
        flush()
        return spans
    }

    /// Keyword-biasing hints for `phraseList`: enabled glossary terms (a term
    /// like "Fabrikam or Northwind" or "Litware, Tailspin" yields each name) and
    /// the targets of enabled word replacements, de-duplicated
    /// case-insensitively in first-seen order. The glossary's "You" entry
    /// explains the mic speaker's label and is not a word to bias towards.
    static func phraseHints(glossary: [GlossaryTerm], replacements: [WordReplacement]) -> [String] {
        var seen: Set<String> = ["you"]
        var hints: [String] = []
        func add(_ raw: String) {
            let hint = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hint.isEmpty, seen.insert(hint.lowercased()).inserted else { return }
            hints.append(hint)
        }
        for entry in glossary where entry.isEnabled {
            for part in entry.term.components(separatedBy: ",") {
                part.components(separatedBy: " or ").forEach(add)
            }
        }
        for entry in replacements where entry.isEnabled {
            add(entry.replacement)
        }
        return hints
    }

    /// Give each span the locally diarized speaker it overlaps most; a span
    /// that overlaps nothing takes the nearest diarized segment's speaker.
    /// Used when MAI transcribes without diarization (long recordings, or a
    /// failed diarization request) and FluidAudio supplies the speakers.
    static func assignSpeakers(_ spans: [MAISpan], diarization: [DiarizedSegment]) -> [DiarizedSegment] {
        spans.map { span in
            var overlapBySpeaker: [Int: Double] = [:]
            for d in diarization {
                let overlap = min(span.end, d.end) - max(span.start, d.start)
                if overlap > 0 { overlapBySpeaker[d.speakerId, default: 0] += overlap }
            }
            let speaker = overlapBySpeaker.max { $0.value < $1.value }?.key
                ?? diarization.min { distance(span, $0) < distance(span, $1) }?.speakerId
                ?? 0
            return DiarizedSegment(start: span.start, end: span.end, speakerId: speaker)
        }
    }

    private static func distance(_ span: MAISpan, _ d: DiarizedSegment) -> Double {
        max(d.start - span.end, span.start - d.end, 0)
    }

    /// Split a recording that is longer than one request allows into equal
    /// chunks, moving each cut to the quietest half-second within
    /// `searchSeconds` of its ideal position so words aren't cut in half.
    /// Returns sample-index ranges that tile the whole input.
    static func chunkRanges(samples: [Float],
                            sampleRate: Double,
                            maxChunkSeconds: Double,
                            searchSeconds: Double) -> [Range<Int>] {
        let total = samples.count
        let maxLength = Int(maxChunkSeconds * sampleRate)
        guard maxLength > 0, total > maxLength else { return [0..<total] }

        let count = Int((Double(total) / Double(maxLength)).rounded(.up))
        let window = max(1, Int(0.5 * sampleRate))
        let step = max(1, window / 4)
        let search = Int(searchSeconds * sampleRate)

        var cuts: [Int] = [0]
        for k in 1..<count {
            let ideal = total * k / count
            var cut = ideal
            var quietest = Float.infinity
            var windowStart = max(0, ideal - search)
            while windowStart + window <= min(total, ideal + search) {
                var energy: Float = 0
                for i in windowStart..<(windowStart + window) { energy += samples[i] * samples[i] }
                if energy < quietest {
                    quietest = energy
                    cut = windowStart + window / 2
                }
                windowStart += step
            }
            cuts.append(cut)
        }
        cuts.append(total)
        return zip(cuts, cuts.dropFirst()).map { $0..<$1 }
    }
}
