import XCTest
@testable import MeetingTranscriber

/// Parakeet returns one flat token stream with timings; the segmenter turns
/// it into transcript-sized segments the merger can interleave with the
/// diarizer's output.
final class ParakeetSegmenterTests: XCTestCase {

    private func tok(_ text: String, _ start: Double, _ end: Double) -> ParakeetToken {
        ParakeetToken(text: text, start: start, end: end)
    }

    func testJoinsTokensIntoOneTrimmedSegment() {
        let segs = ParakeetSegmenter.segments(from: [
            tok(" hello", 0.0, 0.3), tok(" world", 0.4, 0.8)
        ])
        XCTAssertEqual(segs, [WhisperSegment(start: 0.0, end: 0.8, text: "hello world")])
    }

    func testSplitsAfterSentencePunctuation() {
        let segs = ParakeetSegmenter.segments(from: [
            tok(" hi", 0.0, 0.2), tok(".", 0.2, 0.3), tok(" bye", 0.5, 0.7)
        ])
        XCTAssertEqual(segs.map(\.text), ["hi.", "bye"])
        XCTAssertEqual(segs[0].end, 0.3)
        XCTAssertEqual(segs[1].start, 0.5)
    }

    func testSplitsOnSilenceGap() {
        let segs = ParakeetSegmenter.segments(from: [
            tok(" one", 0.0, 0.3), tok(" two", 0.4, 0.6),
            tok(" three", 2.0, 2.3)   // 1.4 s gap > 0.8 s threshold
        ])
        XCTAssertEqual(segs.map(\.text), ["one two", "three"])
    }

    func testSplitsWhenSegmentExceedsMaxDuration() {
        var tokens: [ParakeetToken] = []
        for i in 0..<40 {   // 40 words, 0.5 s each, no punctuation → 20 s
            let s = Double(i) * 0.5
            tokens.append(tok(" w\(i)", s, s + 0.4))
        }
        let segs = ParakeetSegmenter.segments(from: tokens)
        XCTAssertGreaterThan(segs.count, 1)
        for seg in segs {
            XCTAssertLessThanOrEqual(seg.end - seg.start, 15.0 + 0.001)
        }
        XCTAssertEqual(segs.map(\.text).joined(separator: " ").split(separator: " ").count, 40)
    }

    func testDropsWhitespaceOnlyOutput() {
        XCTAssertEqual(ParakeetSegmenter.segments(from: [tok(" ", 0, 0.1)]), [])
        XCTAssertEqual(ParakeetSegmenter.segments(from: []), [])
    }
}
