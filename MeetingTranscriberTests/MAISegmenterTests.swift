import XCTest
@testable import MeetingTranscriber

/// MAI-Transcribe-2 returns speaker turns ("phrases") with word timings; the
/// segmenter turns them into transcript-sized segments with a speaker each.
final class MAISegmenterTests: XCTestCase {

    private func word(_ text: String, _ start: Double, _ end: Double) -> MAIPhrase.Word {
        MAIPhrase.Word(text: text,
                       offsetMilliseconds: start * 1000,
                       durationMilliseconds: (end - start) * 1000)
    }

    private func phrase(_ speaker: Int?, _ words: [MAIPhrase.Word]) -> MAIPhrase {
        let start = words.first?.offsetMilliseconds ?? 0
        let end = words.last.map { $0.offsetMilliseconds + $0.durationMilliseconds } ?? 0
        return MAIPhrase(speaker: speaker,
                         offsetMilliseconds: start,
                         durationMilliseconds: end - start,
                         text: words.map(\.text).joined(separator: " "),
                         words: words)
    }

    // MARK: – spans(from:)

    func testJoinsWordsWithSpacesAndSplitsAfterSentenceEnd() {
        let spans = MAISegmenter.spans(from: [
            phrase(0, [word("Dzień", 0.0, 0.3), word("dobry.", 0.4, 0.8),
                       word("Jak", 1.0, 1.2), word("leci?", 1.3, 1.6)])
        ])
        XCTAssertEqual(spans, [
            MAISpan(start: 0.0, end: 0.8, text: "Dzień dobry.", speaker: 0),
            MAISpan(start: 1.0, end: 1.6, text: "Jak leci?", speaker: 0)
        ])
    }

    func testSplitsWhenSpeakerChanges() {
        let spans = MAISegmenter.spans(from: [
            phrase(0, [word("no", 0.0, 0.2), word("tak", 0.3, 0.5)]),
            phrase(1, [word("jasne", 0.6, 0.9)])
        ])
        XCTAssertEqual(spans.map(\.text), ["no tak", "jasne"])
        XCTAssertEqual(spans.map(\.speaker), [0, 1])
    }

    func testKeepsAccumulatingAcrossPhrasesOfTheSameSpeaker() {
        let spans = MAISegmenter.spans(from: [
            phrase(0, [word("pierwsza", 0.0, 0.4)]),
            phrase(0, [word("część", 0.5, 0.9)])
        ])
        XCTAssertEqual(spans.map(\.text), ["pierwsza część"])
    }

    func testPhrasesWithoutSpeakerYieldNilSpeaker() {
        let spans = MAISegmenter.spans(from: [
            phrase(nil, [word("hello.", 0.0, 0.5)])
        ])
        XCTAssertEqual(spans, [MAISpan(start: 0.0, end: 0.5, text: "hello.", speaker: nil)])
    }

    func testCapsSegmentLengthAtThirtySeconds() {
        let words = (0..<80).map { i in word("w\(i)", Double(i) * 0.5, Double(i) * 0.5 + 0.4) }
        let spans = MAISegmenter.spans(from: [phrase(0, words)])
        XCTAssertGreaterThan(spans.count, 1)
        for span in spans {
            XCTAssertLessThanOrEqual(span.end - span.start, 30.5)
        }
        XCTAssertEqual(spans.map(\.text).joined(separator: " ").split(separator: " ").count, 80)
    }

    func testPhraseWithoutWordTimingsBecomesOneSegment() {
        let spans = MAISegmenter.spans(from: [
            MAIPhrase(speaker: 2, offsetMilliseconds: 5000, durationMilliseconds: 1500,
                      text: "Okay.", words: nil)
        ])
        XCTAssertEqual(spans, [MAISpan(start: 5.0, end: 6.5, text: "Okay.", speaker: 2)])
    }

    func testOffsetShiftsAllTimes() {
        let spans = MAISegmenter.spans(from: [phrase(0, [word("drugi.", 1.0, 1.5)])],
                                       offset: 6600)
        XCTAssertEqual(spans.first?.start, 6601.0)
        XCTAssertEqual(spans.first?.end, 6601.5)
    }

    func testDropsEmptyWords() {
        let spans = MAISegmenter.spans(from: [phrase(0, [word(" ", 0, 0.1)])])
        XCTAssertEqual(spans, [])
    }

    // MARK: – phraseHints

    func testPhraseHintsUseEnabledGlossaryTermsAndReplacementTargets() {
        let hints = MAISegmenter.phraseHints(
            glossary: [
                GlossaryTerm(term: "Contoso", definition: "client"),
                GlossaryTerm(term: "Fabrikam or Northwind", definition: "suppliers"),
                GlossaryTerm(term: "Hidden", definition: "", isEnabled: false)
            ],
            replacements: [
                WordReplacement(original: "NA10", replacement: "n8n"),
                WordReplacement(original: "NITN", replacement: "n8n"),
                WordReplacement(original: "x", replacement: "Off", isEnabled: false)
            ])
        XCTAssertEqual(hints, ["Contoso", "Fabrikam", "Northwind", "n8n"])
    }

    func testPhraseHintsDeduplicateCaseInsensitively() {
        let hints = MAISegmenter.phraseHints(
            glossary: [GlossaryTerm(term: "n8n", definition: ""),
                       GlossaryTerm(term: "Litware, Tailspin", definition: "")],
            replacements: [WordReplacement(original: "NA 10", replacement: "N8N")])
        XCTAssertEqual(hints, ["n8n", "Litware", "Tailspin"])
    }

    func testPhraseHintsSkipTheYouSpeakerPlaceholder() {
        // "You" is the app's label for the mic speaker, not a word to bias
        // English recognition towards.
        let hints = MAISegmenter.phraseHints(
            glossary: [GlossaryTerm(term: "You", definition: "The person recording"),
                       GlossaryTerm(term: "Contoso", definition: "client")],
            replacements: [])
        XCTAssertEqual(hints, ["Contoso"])
    }

    // MARK: – assignSpeakers

    func testAssignSpeakersPicksLargestOverlap() {
        let spans = [MAISpan(start: 0, end: 4, text: "a", speaker: nil),
                     MAISpan(start: 5, end: 8, text: "b", speaker: nil)]
        let diar = [DiarizedSegment(start: 0, end: 1, speakerId: 7),
                    DiarizedSegment(start: 1, end: 5, speakerId: 3),
                    DiarizedSegment(start: 5, end: 9, speakerId: 7)]
        XCTAssertEqual(MAISegmenter.assignSpeakers(spans, diarization: diar), [
            DiarizedSegment(start: 0, end: 4, speakerId: 3),
            DiarizedSegment(start: 5, end: 8, speakerId: 7)
        ])
    }

    func testAssignSpeakersFallsBackToNearestSegment() {
        let spans = [MAISpan(start: 10, end: 11, text: "a", speaker: nil)]
        let diar = [DiarizedSegment(start: 0, end: 2, speakerId: 1),
                    DiarizedSegment(start: 12, end: 14, speakerId: 4)]
        XCTAssertEqual(MAISegmenter.assignSpeakers(spans, diarization: diar).map(\.speakerId), [4])
    }

    func testAssignSpeakersWithoutDiarizationUsesSpeakerZero() {
        let spans = [MAISpan(start: 0, end: 1, text: "a", speaker: nil)]
        XCTAssertEqual(MAISegmenter.assignSpeakers(spans, diarization: []).map(\.speakerId), [0])
    }

    // MARK: – chunkRanges

    func testShortAudioIsOneChunk() {
        let samples = [Float](repeating: 0.5, count: 100)
        XCTAssertEqual(MAISegmenter.chunkRanges(samples: samples, sampleRate: 10,
                                                maxChunkSeconds: 20, searchSeconds: 2),
                       [0..<100])
    }

    func testLongAudioSplitsAtQuietestPointNearIdealBoundary() {
        // 30 s at 10 Hz, loud everywhere except a quiet second at 16–17 s.
        var samples = [Float](repeating: 0.5, count: 300)
        for i in 160..<170 { samples[i] = 0 }
        let ranges = MAISegmenter.chunkRanges(samples: samples, sampleRate: 10,
                                              maxChunkSeconds: 20, searchSeconds: 3)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, 300)
        XCTAssertEqual(ranges[0].upperBound, ranges[1].lowerBound)
        XCTAssertTrue((160...170).contains(ranges[0].upperBound), "cut at \(ranges[0].upperBound)")
    }

    func testChunksCoverAudioWithoutExceedingLimit() {
        let samples = [Float](repeating: 0.5, count: 1000)  // 100 s
        let ranges = MAISegmenter.chunkRanges(samples: samples, sampleRate: 10,
                                              maxChunkSeconds: 30, searchSeconds: 2)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(ranges.map(\.count).reduce(0, +), 1000)
        for r in ranges { XCTAssertLessThanOrEqual(r.count, 300) }
    }
}
