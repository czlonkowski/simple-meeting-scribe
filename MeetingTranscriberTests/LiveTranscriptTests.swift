import XCTest
@testable import MeetingTranscriber

@MainActor
final class LiveTranscriptTests: XCTestCase {

    func testSegmentsStaySortedWhenStreamsArriveOutOfOrder() {
        let live = LiveTranscript()
        live.begin(recordingStart: Date(timeIntervalSince1970: 0))
        live.append(speaker: .me, start: 20, text: "second")
        live.append(speaker: .others, start: 5, text: "first")
        live.append(speaker: .me, start: 30, text: "third")
        XCTAssertEqual(live.segments.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(live.cursor, 3)
    }

    func testEmptyTextIsIgnored() {
        let live = LiveTranscript()
        live.begin(recordingStart: Date())
        live.append(speaker: .me, start: 0, text: "   ")
        XCTAssertTrue(live.segments.isEmpty)
        XCTAssertEqual(live.cursor, 0)
    }

    func testResumingTheSameRecordingKeepsText() {
        let start = Date(timeIntervalSince1970: 100)
        let live = LiveTranscript()
        live.begin(recordingStart: start)
        live.append(speaker: .me, start: 1, text: "kept")
        live.end()
        live.begin(recordingStart: start)
        XCTAssertEqual(live.segments.map(\.text), ["kept"])
        XCTAssertEqual(live.status, .loading)
    }

    func testANewRecordingClearsText() {
        let live = LiveTranscript()
        live.begin(recordingStart: Date(timeIntervalSince1970: 100))
        live.append(speaker: .me, start: 1, text: "old")
        live.end()
        live.begin(recordingStart: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(live.segments.isEmpty)
        XCTAssertEqual(live.cursor, 0)
    }

    func testTurnsJoinConsecutiveSegmentsOfOneSpeaker() {
        let segments = [
            LiveSegment(id: 1, speaker: .others, start: 0, text: "Dzień dobry,"),
            LiveSegment(id: 2, speaker: .others, start: 11, text: "zaczynamy."),
            LiveSegment(id: 3, speaker: .me, start: 22, text: "Hello."),
            LiveSegment(id: 4, speaker: .others, start: 33, text: "OK.")
        ]
        let turns = LiveTranscriptFormat.turns(segments)
        XCTAssertEqual(turns.map(\.text), ["Dzień dobry, zaczynamy.", "Hello.", "OK."])
        XCTAssertEqual(turns.map(\.start), [0, 22, 33])
    }

    func testMarkdownNamesSpeakersAndTimes() {
        let segments = [
            LiveSegment(id: 1, speaker: .me, start: 65, text: "Hi."),
            LiveSegment(id: 2, speaker: .others, start: 3_725, text: "Bye.")
        ]
        XCTAssertEqual(LiveTranscriptFormat.markdown(segments, myName: "Romuald"),
                       "**[1:05] Romuald:** Hi.\n\n**[1:02:05] Others:** Bye.")
    }

    func testRecentKeepsTheWindowBeforeTheNewestSegment() {
        let segments = (0..<10).map {
            LiveSegment(id: $0 + 1, speaker: .me, start: TimeInterval($0 * 60), text: "\($0)")
        }
        let recent = LiveTranscriptFormat.recent(segments, seconds: 300)
        XCTAssertEqual(recent.map(\.text), ["4", "5", "6", "7", "8", "9"])
    }

    func testDisplayNameFallsBackToYou() {
        XCTAssertEqual(LiveTranscriptFormat.displayName(for: "  "), "You")
        XCTAssertEqual(LiveTranscriptFormat.displayName(for: "Romuald"), "Romuald")
    }
}

final class LiveAudioTapTests: XCTestCase {

    func testSendWithoutAttachDoesNothing() {
        LiveAudioTap().send([1, 2, 3], from: .mic)
    }

    func testMutedMicSendsSilenceOfTheSameLength() async {
        let tap = LiveAudioTap()
        let streams = tap.attach()
        tap.setMicMuted(true)
        tap.send([0.5, 0.5], from: .mic)
        tap.detach()
        var received: [[Float]] = []
        for await chunk in streams.mic { received.append(chunk) }
        XCTAssertEqual(received, [[0, 0]])
    }

    func testDropsOldestWhenTheTranscriberFallsBehind() async {
        let tap = LiveAudioTap()
        let streams = tap.attach()
        for i in 0..<(LiveAudioTap.bufferLimit + 5) {
            tap.send([Float(i)], from: .system)
        }
        tap.detach()
        var count = 0
        var first: Float?
        for await chunk in streams.system {
            if first == nil { first = chunk.first }
            count += 1
        }
        XCTAssertEqual(count, LiveAudioTap.bufferLimit)
        XCTAssertEqual(first, 5)
    }

    func testSilenceCoversTheGap() async {
        let tap = LiveAudioTap()
        let streams = tap.attach()
        tap.sendSilence(seconds: 2.5, from: .system)
        tap.detach()
        var total = 0
        for await chunk in streams.system { total += chunk.count }
        XCTAssertEqual(total, 40_000)
    }
}

@MainActor
final class LiveTranscriptPartialTests: XCTestCase {

    func testFinalTextReplacesThatSpeakersPartial() {
        let live = LiveTranscript()
        live.begin(recordingStart: Date())
        live.setPartial("Dzień do", for: .others)
        live.setPartial("Hello", for: .me)
        live.append(speaker: .others, start: 0, text: "Dzień dobry.")
        XCTAssertNil(live.partial[.others])
        XCTAssertEqual(live.partial[.me], "Hello")
    }

    func testPartialsAreNeverInTheCopiedOrServedText() {
        let live = LiveTranscript()
        live.begin(recordingStart: Date())
        live.setPartial("still talking", for: .me)
        XCTAssertEqual(LiveTranscriptFormat.markdown(live.segments, myName: "You"), "")
        live.end()
        XCTAssertTrue(live.partial.isEmpty)
    }
}
