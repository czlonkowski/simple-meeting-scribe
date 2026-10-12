import Foundation
import XCTest
@testable import MeetingTranscriber

final class CallActivityTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func client(_ bundleID: String, input: Bool, output: Bool,
                        path: String = "/Applications/App.app/Contents/MacOS/App") -> AudioClientSnapshot {
        AudioClientSnapshot(pid: 42, bundleID: bundleID, executablePath: path,
                            isRunningInput: input, isRunningOutput: output)
    }

    func testTwoWayAudioForMinimumDurationReportsOnce() {
        var tracker = CallActivityTracker()
        let call = [client("net.whatsapp.WhatsApp", input: true, output: true)]
        XCTAssertTrue(tracker.update(clients: call, at: t0).isEmpty)
        XCTAssertTrue(tracker.update(clients: call, at: t0 + 2).isEmpty)
        let starts = tracker.update(clients: call, at: t0 + 3)
        XCTAssertEqual(starts.map(\.app.name), ["WhatsApp"])
        XCTAssertEqual(starts.first?.startedAt, t0)
        XCTAssertTrue(tracker.update(clients: call, at: t0 + 60).isEmpty)
    }

    func testActiveCallsIncludeCallsAlreadyReportedOrStillTooYoung() {
        var tracker = CallActivityTracker()
        let call = [client("", input: true, output: true, path: "/usr/libexec/avconferenced")]
        XCTAssertTrue(tracker.activeCalls(clients: [], at: t0).isEmpty)
        // Seen in a poll but younger than the minimum duration.
        _ = tracker.update(clients: call, at: t0)
        XCTAssertEqual(tracker.activeCalls(clients: call, at: t0 + 1).map(\.app.name), ["Phone"])
        // Reported long ago: `update` stays quiet, the call is still active.
        _ = tracker.update(clients: call, at: t0 + 3)
        XCTAssertTrue(tracker.update(clients: call, at: t0 + 60).isEmpty)
        let active = tracker.activeCalls(clients: call, at: t0 + 60)
        XCTAssertEqual(active.first?.startedAt, t0)
        XCTAssertEqual(active.first?.app.tapExecutableNames, ["avconferenced"])
        // One direction only is not a call.
        let playback = [client("", input: false, output: true, path: "/usr/libexec/avconferenced")]
        XCTAssertTrue(tracker.activeCalls(clients: playback, at: t0 + 61).isEmpty)
    }

    func testHangUpIsReportedOnceAfterBothDirectionsStayQuiet() {
        var tracker = CallActivityTracker()
        let call = [client("net.whatsapp.WhatsApp", input: true, output: true)]
        XCTAssertTrue(tracker.endedCalls(clients: call, at: t0).isEmpty)
        XCTAssertTrue(tracker.endedCalls(clients: [], at: t0 + 10).isEmpty)
        XCTAssertTrue(tracker.endedCalls(clients: [], at: t0 + 14).isEmpty)
        XCTAssertEqual(tracker.endedCalls(clients: [], at: t0 + 15).map(\.name), ["WhatsApp"])
        XCTAssertTrue(tracker.endedCalls(clients: [], at: t0 + 60).isEmpty)
    }

    func testMutedMicOrBriefDropoutDoesNotEndTheCall() {
        var tracker = CallActivityTracker()
        let call = [client("net.whatsapp.WhatsApp", input: true, output: true)]
        let muted = [client("net.whatsapp.WhatsApp", input: false, output: true)]
        _ = tracker.endedCalls(clients: call, at: t0)
        // One direction still running, however long.
        XCTAssertTrue(tracker.endedCalls(clients: muted, at: t0 + 10).isEmpty)
        XCTAssertTrue(tracker.endedCalls(clients: muted, at: t0 + 300).isEmpty)
        // Quiet for less than the grace period, then back.
        XCTAssertTrue(tracker.endedCalls(clients: [], at: t0 + 301).isEmpty)
        XCTAssertTrue(tracker.endedCalls(clients: call, at: t0 + 304).isEmpty)
        XCTAssertTrue(tracker.endedCalls(clients: [], at: t0 + 305).isEmpty)
        XCTAssertTrue(tracker.endedCalls(clients: [], at: t0 + 309).isEmpty)
        XCTAssertEqual(tracker.endedCalls(clients: [], at: t0 + 310).count, 1)
    }

    func testHangUpNeedsACallFirstAndADetectableApp() {
        var tracker = CallActivityTracker()
        // Never two-way: playback stopping is not a hang-up.
        _ = tracker.endedCalls(clients: [client("net.whatsapp.WhatsApp", input: false, output: true)], at: t0)
        XCTAssertTrue(tracker.endedCalls(clients: [], at: t0 + 30).isEmpty)
        // Zoom may release audio mid-meeting, so it never auto-ends.
        _ = tracker.endedCalls(clients: [client("us.zoom.xos", input: true, output: true)], at: t0 + 40)
        XCTAssertTrue(tracker.endedCalls(clients: [], at: t0 + 100).isEmpty)
    }

    func testInputAndOutputMayComeFromDifferentHelperProcesses() {
        var tracker = CallActivityTracker()
        let call = [client("net.whatsapp.WhatsApp", input: true, output: false),
                    client("net.whatsapp.WhatsApp.helper", input: false, output: true)]
        _ = tracker.update(clients: call, at: t0)
        XCTAssertEqual(tracker.update(clients: call, at: t0 + 3).count, 1)
    }

    func testVoiceNoteAndPlaybackAreNotCalls() {
        var tracker = CallActivityTracker()
        let voiceNote = [client("net.whatsapp.WhatsApp", input: true, output: false)]
        let playback = [client("net.whatsapp.WhatsApp", input: false, output: true)]
        for second in 0...10 {
            XCTAssertTrue(tracker.update(clients: second.isMultiple(of: 2) ? voiceNote : playback,
                                         at: t0 + TimeInterval(second)).isEmpty)
        }
    }

    func testShortBlipIsIgnored() {
        var tracker = CallActivityTracker()
        let call = [client("net.whatsapp.WhatsApp", input: true, output: true)]
        _ = tracker.update(clients: call, at: t0)
        _ = tracker.update(clients: call, at: t0 + 2)
        XCTAssertTrue(tracker.update(clients: [], at: t0 + 2.5).isEmpty)
        XCTAssertTrue(tracker.update(clients: call, at: t0 + 4).isEmpty)
    }

    func testNextCallReportsAfterMicIsReleased() {
        var tracker = CallActivityTracker()
        let call = [client("net.whatsapp.WhatsApp", input: true, output: true)]
        _ = tracker.update(clients: call, at: t0)
        XCTAssertEqual(tracker.update(clients: call, at: t0 + 3).count, 1)
        // Output pausing mid-call (silence) must not re-arm the trigger.
        _ = tracker.update(clients: [client("net.whatsapp.WhatsApp", input: true, output: false)], at: t0 + 10)
        _ = tracker.update(clients: call, at: t0 + 11)
        XCTAssertTrue(tracker.update(clients: call, at: t0 + 20).isEmpty)
        // Hang up, then a new call.
        _ = tracker.update(clients: [], at: t0 + 30)
        _ = tracker.update(clients: call, at: t0 + 40)
        XCTAssertEqual(tracker.update(clients: call, at: t0 + 43).count, 1)
    }

    func testDaemonsMatchByExecutableName() {
        var tracker = CallActivityTracker()
        let call = [client("", input: true, output: true, path: "/usr/libexec/avconferenced")]
        _ = tracker.update(clients: call, at: t0)
        XCTAssertEqual(tracker.update(clients: call, at: t0 + 3).map(\.app.name), ["Phone"])
    }

    func testBrowsersAndThisAppAreIgnored() {
        var tracker = CallActivityTracker()
        let clients = [client("company.thebrowser.browser.helper", input: true, output: true),
                       client("com.czlonkowski.MeetingTranscriber", input: true, output: true)]
        _ = tracker.update(clients: clients, at: t0)
        XCTAssertTrue(tracker.update(clients: clients, at: t0 + 10).isEmpty)
    }
}
