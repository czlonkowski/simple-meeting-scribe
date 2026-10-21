import XCTest
@testable import MeetingTranscriber

final class MeetingEndTrackerTests: XCTestCase {
    private let speech: Float = 0.05
    private let quiet: Float = 0.000_1

    private func run(_ tracker: inout MeetingEndTracker, seconds: Int,
                     app: Bool, system: Float, mic: Float) -> [MeetingEndTracker.Reason] {
        (0..<seconds).compactMap { _ in
            tracker.tick(meetingAppUsesMic: app, systemRMS: system, micRMS: mic)
        }
    }

    func testLeavingTheMeetingAppFiresOnceAfterGrace() {
        var t = MeetingEndTracker()
        XCTAssertEqual(run(&t, seconds: 60, app: true, system: speech, mic: speech), [])
        XCTAssertEqual(run(&t, seconds: 9, app: false, system: quiet, mic: speech), [])
        XCTAssertEqual(run(&t, seconds: 1, app: false, system: quiet, mic: speech), [.appLeft])
        XCTAssertEqual(run(&t, seconds: 120, app: false, system: quiet, mic: speech), [])
    }

    func testMicReleasedWhileOthersTalkDoesNotFire() {
        // Muting may release the mic; remote speech means the meeting goes on.
        var t = MeetingEndTracker()
        _ = run(&t, seconds: 30, app: true, system: speech, mic: speech)
        XCTAssertEqual(run(&t, seconds: 120, app: false, system: speech, mic: quiet), [])
    }

    func testAppThatNeverUsedTheMicDoesNotFire() {
        var t = MeetingEndTracker()
        XCTAssertEqual(run(&t, seconds: 3, app: true, system: speech, mic: speech), [])
        XCTAssertEqual(run(&t, seconds: 60, app: false, system: quiet, mic: speech), [])
    }

    func testRejoiningRearmsAppLeft() {
        var t = MeetingEndTracker()
        _ = run(&t, seconds: 30, app: true, system: speech, mic: speech)
        XCTAssertEqual(run(&t, seconds: 10, app: false, system: quiet, mic: speech), [.appLeft])
        _ = run(&t, seconds: 30, app: true, system: speech, mic: speech)
        XCTAssertEqual(run(&t, seconds: 10, app: false, system: quiet, mic: speech), [.appLeft])
    }

    func testSilenceFiresAfterThreeMinutesOnly() {
        var t = MeetingEndTracker()
        // The longest shared quiet measured inside a real meeting was 49 s.
        XCTAssertEqual(run(&t, seconds: 179, app: false, system: quiet, mic: quiet), [])
        XCTAssertEqual(run(&t, seconds: 1, app: false, system: quiet, mic: quiet), [.silence])
        XCTAssertEqual(run(&t, seconds: 600, app: false, system: quiet, mic: quiet), [])
        _ = run(&t, seconds: 1, app: false, system: speech, mic: quiet)
        XCTAssertEqual(run(&t, seconds: 180, app: false, system: quiet, mic: quiet), [.silence])
    }

    func testSpeechOnEitherSideResetsSilence() {
        var t = MeetingEndTracker()
        XCTAssertEqual(run(&t, seconds: 170, app: false, system: quiet, mic: quiet), [])
        XCTAssertEqual(run(&t, seconds: 1, app: false, system: quiet, mic: speech), [])
        XCTAssertEqual(run(&t, seconds: 170, app: false, system: quiet, mic: quiet), [])
    }

    func testAppLeftSuppressesTheFollowingSilencePrompt() {
        var t = MeetingEndTracker()
        _ = run(&t, seconds: 30, app: true, system: speech, mic: speech)
        XCTAssertEqual(run(&t, seconds: 400, app: false, system: quiet, mic: quiet), [.appLeft])
    }

    func testMeetingAppMatching() {
        func client(_ bundle: String) -> AudioClientSnapshot {
            AudioClientSnapshot(pid: 1, bundleID: bundle, executablePath: "", isRunningInput: true, isRunningOutput: true)
        }
        XCTAssertTrue(MeetingEndTracker.isMeetingApp(client("company.thebrowser.browser.helper")))
        XCTAssertTrue(MeetingEndTracker.isMeetingApp(client("com.google.Chrome.helper")))
        XCTAssertTrue(MeetingEndTracker.isMeetingApp(client("com.apple.WebKit.GPU")))
        XCTAssertTrue(MeetingEndTracker.isMeetingApp(client("com.microsoft.teams2")))
        XCTAssertFalse(MeetingEndTracker.isMeetingApp(client("com.czlonkowski.MeetingTranscriber")))
        XCTAssertFalse(MeetingEndTracker.isMeetingApp(client("net.whatsapp.WhatsApp")))
    }

    func testLevelAccumulatorAveragesPower() {
        var acc = LevelAccumulator()
        XCTAssertEqual(acc.take(), 0)
        acc.add(0.3); acc.add(0.4)
        XCTAssertEqual(acc.take(), (0.125 as Float).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(acc.take(), 0)
    }
}
