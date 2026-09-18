import XCTest
@testable import MeetingTranscriber

/// Speaker mapping for the cloud path: one diarized transcript of the stem
/// mix, with per-segment stem levels telling local (mic) from remote (system)
/// speech.
final class TranscriptMergerTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ text: String = "x") -> WhisperSegment {
        WhisperSegment(start: start, end: end, text: text)
    }

    private func diar(_ segments: [WhisperSegment], _ speakers: [Int]) -> [DiarizedSegment] {
        zip(segments, speakers).map { DiarizedSegment(start: $0.start, end: $0.end, speakerId: $1) }
    }

    private let local = StemLevels(mic: -40, system: -120)
    private let remote = StemLevels(mic: -60, system: -25)

    private func names(_ result: (segments: [TranscriptSegment], speakers: [SpeakerLabel])) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: result.speakers.map { ($0.id, $0.name) })
        return result.segments.map { byID[$0.speakerId] ?? "?" }
    }

    func testRemoteSpeechMergedIntoTheUsersSpeakerIsSplitOff() {
        // The 2026-09-18 YouTube test: the cloud gave one speaker for the user
        // and a video playing through the system stem.
        let segs = [seg(0.6, 3.0), seg(3.4, 5.7), seg(7.0, 10.4), seg(11.4, 14.1)]
        let result = TranscriptMerger.mapDiarizedSingle(
            segments: segs, diarization: diar(segs, [0, 0, 0, 0]),
            stemLevels: [local, local, StemLevels(mic: -55, system: -24), local])
        XCTAssertEqual(names(result), ["You", "You", "Remote", "You"])
    }

    func testTheMostlyLocalSpeakerIsYou() {
        let segs = [seg(0, 2), seg(2, 4), seg(4, 6), seg(6, 8)]
        let result = TranscriptMerger.mapDiarizedSingle(
            segments: segs, diarization: diar(segs, [5, 3, 5, 3]),
            stemLevels: [remote, local, remote, local])
        XCTAssertEqual(names(result), ["Remote", "You", "Remote", "You"])
        XCTAssertEqual(result.speakers.map(\.name), ["You", "Remote"])
    }

    func testDoubleTalkKeepsTheCloudSpeaker() {
        // Remote talking over the user: system a little louder, but the words
        // are the user's — the cloud identity wins below the 20 dB margin.
        let segs = [seg(0, 2), seg(2, 4), seg(4, 6)]
        let result = TranscriptMerger.mapDiarizedSingle(
            segments: segs, diarization: diar(segs, [0, 0, 1]),
            stemLevels: [local, StemLevels(mic: -29, system: -19), remote])
        XCTAssertEqual(names(result), ["You", "You", "Remote"])
    }

    func testClearlyLocalSegmentOfARemoteSpeakerBecomesYou() {
        let segs = [seg(0, 2), seg(2, 4), seg(4, 6)]
        let result = TranscriptMerger.mapDiarizedSingle(
            segments: segs, diarization: diar(segs, [0, 1, 1]),
            stemLevels: [local, remote, StemLevels(mic: -23, system: -87)])
        XCTAssertEqual(names(result), ["You", "Remote", "You"])
    }

    func testSeveralRemoteSpeakersAreNumberedByFirstAppearance() {
        let segs = [seg(0, 2), seg(2, 4), seg(4, 6), seg(6, 8)]
        let result = TranscriptMerger.mapDiarizedSingle(
            segments: segs, diarization: diar(segs, [7, 0, 4, 7]),
            stemLevels: [remote, local, remote, remote])
        XCTAssertEqual(names(result), ["Remote 1", "You", "Remote 2", "Remote 1"])
    }

    func testNoLocalSpeechMeansNoYou() {
        let segs = [seg(0, 2), seg(2, 4)]
        let result = TranscriptMerger.mapDiarizedSingle(
            segments: segs, diarization: diar(segs, [0, 1]),
            stemLevels: [remote, remote])
        XCTAssertEqual(names(result), ["Remote 1", "Remote 2"])
    }

    func testWithoutStemLevelsSpeakersAreNumbered() {
        // Imported files have a single stem: nothing tells local from remote.
        let segs = [seg(0, 2), seg(2, 4), seg(4, 6)]
        let result = TranscriptMerger.mapDiarizedSingle(
            segments: segs, diarization: diar(segs, [2, 0, 2]), stemLevels: nil)
        XCTAssertEqual(names(result), ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    // MARK: – Stem levels

    func testStemLevelsMeasureEachSegmentInDecibels() {
        // 10 Hz "audio": mic loud in the first second, system in the second.
        let mic = [Float](repeating: 0.1, count: 10) + [Float](repeating: 0, count: 10)
        let system = [Float](repeating: 0, count: 10) + [Float](repeating: 0.5, count: 10)
        let levels = AudioMixdown.stemLevels(voice: mic, system: system, sampleRate: 10,
                                             segments: [seg(0, 1), seg(1, 2)])
        XCTAssertEqual(levels[0].mic, -20, accuracy: 0.01)
        XCTAssertLessThanOrEqual(levels[0].system, -100)
        XCTAssertEqual(levels[1].system, -6.02, accuracy: 0.01)
        XCTAssertLessThanOrEqual(levels[1].mic, -100)
    }

    func testStemLevelsClampSegmentsToTheShorterStem() {
        let levels = AudioMixdown.stemLevels(voice: [0.1, 0.1], system: [0.1],
                                             sampleRate: 1, segments: [seg(0, 5), seg(3, 4)])
        XCTAssertEqual(levels.count, 2)
        XCTAssertEqual(levels[0].mic, -20, accuracy: 0.01)
        XCTAssertLessThanOrEqual(levels[1].mic, -100)  // past both stems: silence
    }
}
