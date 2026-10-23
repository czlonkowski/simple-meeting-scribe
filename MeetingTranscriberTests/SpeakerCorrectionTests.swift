import XCTest
@testable import MeetingTranscriber

final class SpeakerCorrectionTests: XCTestCase {

    private func seg(_ start: Double, _ speaker: Int, _ text: String = "x") -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 1, speakerId: speaker, text: text)
    }

    private func doc(kind: TranscriptDocument.SourceKind = .live,
                     segments: [TranscriptSegment]) -> TranscriptDocument {
        let ids = Set(segments.map(\.speakerId)).sorted()
        return TranscriptDocument(
            id: "t", title: "T", date: Date(timeIntervalSince1970: 0), duration: 60,
            language: .polish, modelShortName: "mai", sourceKind: kind,
            speakers: ids.map { SpeakerLabel(id: $0, name: $0 == 1 ? "You" : "Remote \($0 - 1)") },
            segments: segments, audioFileName: nil)
    }

    // MARK: - Eligibility

    func testNeedsTwoMovableSpeakers() {
        XCTAssertFalse(SpeakerCorrection.isApplicable(to: doc(segments: [seg(0, 1), seg(1, 2)])))
        XCTAssertTrue(SpeakerCorrection.isApplicable(to: doc(segments: [seg(0, 1), seg(1, 2), seg(2, 3)])))
        // Imported files have no mic stem, so speaker 1 is an ordinary speaker.
        XCTAssertTrue(SpeakerCorrection.isApplicable(to: doc(kind: .imported, segments: [seg(0, 1), seg(1, 2)])))
    }

    func testReasoningIsRaisedToMediumButNeverForcedOnNonReasoningModels() {
        XCTAssertEqual(SpeakerCorrection.reasoningEffort(for: .none), .medium)
        XCTAssertEqual(SpeakerCorrection.reasoningEffort(for: .low), .medium)
        XCTAssertEqual(SpeakerCorrection.reasoningEffort(for: .medium), .medium)
        XCTAssertEqual(SpeakerCorrection.reasoningEffort(for: .high), .high)
        XCTAssertEqual(SpeakerCorrection.reasoningEffort(for: .modelDefault), .modelDefault)
    }

    // MARK: - Windows

    func testWindowsSplitByStartTimeWithContextOnBothSides() {
        // One segment per minute for 40 minutes → windows at 0, 15, 30 min.
        let segments = (0..<40).map { seg(Double($0) * 60, 2 + $0 % 2) }
        let windows = SpeakerCorrection.windows(for: segments)
        XCTAssertEqual(windows.map(\.editable), [0...14, 15...29, 30...39])
        XCTAssertEqual(windows.map(\.context), [0...18, 11...33, 26...39])
    }

    func testNoWindowsForEmptyTranscript() {
        XCTAssertEqual(SpeakerCorrection.windows(for: []), [])
    }

    // MARK: - Parsing

    func testParsesRunsInsideFencesAndProse() {
        let raw = """
        Here you go:
        ```json
        {"runs":[{"from":3,"to":5,"speaker":4,"cue":"continues the slides"}]}
        ```
        """
        XCTAssertEqual(SpeakerCorrection.parseRuns(raw),
                       [.init(from: 3, to: 5, speaker: 4, cue: "continues the slides")])
    }

    func testUnparseableReplyYieldsNoRuns() {
        XCTAssertEqual(SpeakerCorrection.parseRuns("no json here"), [])
        XCTAssertEqual(SpeakerCorrection.parseRuns("{\"runs\": 3}"), [])
    }

    // MARK: - Reassignments

    func testReassignmentsStayInsideTheRulesAndTheEditableRange() {
        let segments = [seg(0, 2), seg(1, 3), seg(2, 1), seg(3, 3), seg(4, 3), seg(5, 2)]
        let window = SpeakerCorrection.Window(editable: 1...4, context: 0...5)
        let runs: [SpeakerCorrection.Run] = [
            .init(from: 0, to: 4, speaker: 2, cue: "presenter continues"),   // clipped to 1...4, skips locked line 2
            .init(from: 5, to: 5, speaker: 3, cue: "outside editable"),
            .init(from: 1, to: 1, speaker: 9, cue: "unknown speaker"),
            .init(from: 1, to: 1, speaker: 1, cue: "into the mic speaker"),
            .init(from: 3, to: 3, speaker: 2, cue: nil),
            .init(from: 4, to: 3, speaker: 2, cue: "reversed"),
        ]
        let out = SpeakerCorrection.reassignments(from: runs, window: window, segments: segments,
                                                  speakerIDs: [1, 2, 3], locked: [1])
        XCTAssertEqual(out, [1: 2, 3: 2, 4: 2])
    }

    func testApplyKeepsTheDiarizedSpeaker() {
        let segments = [seg(0, 2), seg(1, 3)]
        let once = SpeakerCorrection.apply([1: 2], to: segments)
        XCTAssertEqual(once.map(\.speakerId), [2, 2])
        XCTAssertEqual(once.map(\.diarizedSpeakerId), [nil, 3])
        XCTAssertEqual(once.map(\.id), segments.map(\.id))
        // A second move still remembers the original diarized speaker.
        let twice = SpeakerCorrection.apply([1: 4], to: once)
        XCTAssertEqual(twice[1].diarizedSpeakerId, 3)
    }

    func testPromptMarksTheMicSpeakerAndTheEditableRange() {
        let d = doc(segments: [seg(0, 1, "Cześć"), seg(65, 2, "Dzień dobry")])
        let prompt = SpeakerCorrection.prompt(window: .init(editable: 1...1, context: 0...1),
                                              segments: d.segments, speakers: d.speakers, locked: [1])
        XCTAssertTrue(prompt.contains("c1 = You (the recording user"))
        XCTAssertTrue(prompt.contains("c2 = Remote 1\n"))
        XCTAssertTrue(prompt.contains("EDITABLE range: L1..L1"))
        XCTAssertTrue(prompt.contains("L0 [0:00] c1: Cześć"))
        XCTAssertTrue(prompt.contains("L1 [1:05] c2: Dzień dobry"))
    }

    // MARK: - Persistence

    func testNewFieldsRoundTripAndOldJSONStillDecodes() throws {
        var d = doc(segments: [seg(0, 2), seg(1, 3)])
        let old = try JSONDecoder().decode(TranscriptDocument.self, from: JSONEncoder().encode(d))
        XCTAssertNil(old.speakersCorrectedAt)
        XCTAssertNil(old.segments[1].diarizedSpeakerId)

        d.segments = SpeakerCorrection.apply([1: 2], to: d.segments)
        d.speakersCorrectedAt = Date(timeIntervalSince1970: 100)
        let decoded = try JSONDecoder().decode(TranscriptDocument.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(decoded.speakersCorrectedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(decoded.segments[1].diarizedSpeakerId, 3)
        XCTAssertEqual(decoded.segments[1].speakerId, 2)
    }
}

final class AzureReasoningOverrideTests: XCTestCase {

    func testRequestBodyUsesTheOverrideWhenGiven() throws {
        let d = AzureDeployment(endpoint: "https://res.openai.azure.com/", deployment: "gpt6luna",
                                reasoningEffort: .none)
        let data = try AzureOpenAIClient.requestBody(deployment: d, prompt: "P", instructions: "S",
                                                     maxCompletionTokens: 100, reasoningEffort: .medium)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["reasoning_effort"] as? String, "medium")
    }
}
