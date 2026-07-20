import XCTest
@testable import MeetingTranscriber

final class ProcessScriptRunnerTests: XCTestCase {
    func testReturnsScriptOutput() async {
        let result = await ProcessScriptRunner().run(
            script: "return \"hello\"",
            timeoutNanoseconds: 1_000_000_000
        )
        XCTAssertEqual(result, .output("hello\n"))
    }

    func testReportsScriptFailure() async {
        let result = await ProcessScriptRunner().run(
            script: "error \"boom\"",
            timeoutNanoseconds: 1_000_000_000
        )
        guard case .failed(let message) = result else {
            return XCTFail("Expected a failed result, got \(result)")
        }
        XCTAssertTrue(message.contains("boom"))
    }

    func testEnforcesHardTimeout() async {
        let startedAt = ContinuousClock.now
        let result = await ProcessScriptRunner().run(
            script: "delay 5\nreturn \"late\"",
            timeoutNanoseconds: 50_000_000
        )
        let elapsed = ContinuousClock.now - startedAt

        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testCancellationTerminatesScript() async {
        let task = Task {
            await ProcessScriptRunner().run(
                script: "delay 5\nreturn \"late\"",
                timeoutNanoseconds: 5_000_000_000
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }
}
