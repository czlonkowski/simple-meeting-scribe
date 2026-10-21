import XCTest
@testable import MeetingTranscriber

final class UpdateControllerTests: XCTestCase {
    func testIdleAppDoesNotDeferUpdates() {
        XCTAssertFalse(UpdateController.mustDefer(recordingState: .idle, isProcessing: false))
    }

    func testRecorderActivityDefersUpdates() {
        let states: [AppState.RecordingState] = [
            .preparing,
            .recording(startedAt: Date(), meeting: nil, language: .english),
            .stopping,
        ]
        for state in states {
            XCTAssertTrue(UpdateController.mustDefer(recordingState: state, isProcessing: false), "\(state)")
        }
    }

    func testTranscriptionQueueDefersUpdates() {
        XCTAssertTrue(UpdateController.mustDefer(recordingState: .idle, isProcessing: true))
    }
}
