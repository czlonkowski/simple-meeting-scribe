import XCTest
@testable import MeetingTranscriber

/// Pins the once-per-recording threshold logic behind the "still recording
/// after 2 hours" notification. One instance lives per recording session, so
/// starting a new recording resets the alert by construction.
final class LongRecordingAlertTests: XCTestCase {

    func testDoesNotFireBeforeThreshold() {
        var alert = LongRecordingAlert()
        XCTAssertFalse(alert.check(elapsedSeconds: 0))
        XCTAssertFalse(alert.check(elapsedSeconds: 7_199))
    }

    func testFiresAtThreshold() {
        var alert = LongRecordingAlert()
        XCTAssertTrue(alert.check(elapsedSeconds: 7_200))
    }

    func testFiresOnlyOncePerInstance() {
        var alert = LongRecordingAlert()
        XCTAssertTrue(alert.check(elapsedSeconds: 7_200))
        XCTAssertFalse(alert.check(elapsedSeconds: 7_201))
        XCTAssertFalse(alert.check(elapsedSeconds: 10_000))
    }

    func testFiresWhenFirstCheckIsAlreadyPastThreshold() {
        // Timer ticks are 1s apart but nothing guarantees we see exactly 7200
        // (e.g. a wedged main thread) — any value past the threshold counts.
        var alert = LongRecordingAlert()
        XCTAssertTrue(alert.check(elapsedSeconds: 9_000))
    }

    func testCustomThreshold() {
        var alert = LongRecordingAlert(thresholdSeconds: 60)
        XCTAssertFalse(alert.check(elapsedSeconds: 59))
        XCTAssertTrue(alert.check(elapsedSeconds: 60))
    }
}
