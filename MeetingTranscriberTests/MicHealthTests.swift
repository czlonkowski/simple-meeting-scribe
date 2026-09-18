import XCTest
@testable import MeetingTranscriber

/// Mic-capture recovery decisions and gap accounting. The 2026-09-17 bug:
/// AirPods reconfiguring the system audio made AVAudioEngine rebuild in a
/// self-feeding loop, the mic delivered nothing for seconds (or for good),
/// and the voice stem silently lost that time.
final class MicHealthTests: XCTestCase {

    // MARK: – MicTimeline (gap padding from buffer host times)

    func testFirstBufferAnchorsTheTimelineWithoutPadding() {
        var timeline = MicTimeline(sampleRate: 16_000)
        XCTAssertEqual(timeline.padding(beforeBufferAt: 1000.0), 0)
    }

    func testContinuousBuffersNeedNoPadding() {
        var timeline = MicTimeline(sampleRate: 16_000)
        for i in 0..<50 {
            XCTAssertEqual(timeline.padding(beforeBufferAt: 1000.0 + Double(i) * 0.1), 0, "buffer \(i)")
            timeline.didWrite(1600)
        }
    }

    func testDeliveryJitterBelowToleranceIsNotPadded() {
        var timeline = MicTimeline(sampleRate: 16_000)
        _ = timeline.padding(beforeBufferAt: 1000.0)
        timeline.didWrite(1600)
        // Next buffer's audio starts 0.2 s later than the samples written so far.
        XCTAssertEqual(timeline.padding(beforeBufferAt: 1000.3), 0)
    }

    func testAGapInCaptureIsPaddedToTheBufferStart() {
        var timeline = MicTimeline(sampleRate: 16_000)
        _ = timeline.padding(beforeBufferAt: 1000.0)
        timeline.didWrite(16_000)                         // 1 s of audio
        let pad = timeline.padding(beforeBufferAt: 1003.0) // next audio starts at +3 s
        XCTAssertEqual(pad, 32_000)
        timeline.didWrite(pad + 1600)
        XCTAssertEqual(timeline.padding(beforeBufferAt: 1003.1), 0, "padding must not repeat")
    }

    func testTimelineAheadOfBufferTimeNeverPadsNegative() {
        var timeline = MicTimeline(sampleRate: 16_000)
        _ = timeline.padding(beforeBufferAt: 1000.0)
        timeline.didWrite(48_000)
        XCTAssertEqual(timeline.padding(beforeBufferAt: 1001.0), 0)
    }

    // MARK: – MicHealth (when to rebuild the engine)

    func testConfigurationChangeIsIgnoredWhileTheMicKeepsDelivering() {
        // Our own device selection on a fresh engine fires a configuration
        // change; rebuilding again for it is what made the loop.
        XCTAssertFalse(MicHealth.needsRebuild(engineRunning: true,
                                              secondsSinceLastBuffer: 0.1,
                                              onPreferredDevice: true))
    }

    func testRebuildWhenTheEngineStoppedOrBuffersStoppedOrDeviceDrifted() {
        XCTAssertTrue(MicHealth.needsRebuild(engineRunning: false, secondsSinceLastBuffer: 0.1, onPreferredDevice: true))
        XCTAssertTrue(MicHealth.needsRebuild(engineRunning: true, secondsSinceLastBuffer: 1.0, onPreferredDevice: true))
        XCTAssertTrue(MicHealth.needsRebuild(engineRunning: true, secondsSinceLastBuffer: nil, onPreferredDevice: true))
        XCTAssertTrue(MicHealth.needsRebuild(engineRunning: true, secondsSinceLastBuffer: 0.1, onPreferredDevice: false))
    }

    func testStallNeedsThreeSecondsWithoutBuffersOnAnEngineOlderThanThat() {
        XCTAssertFalse(MicHealth.isStalled(secondsSinceEngineStart: 2.0, secondsSinceLastBuffer: nil))
        XCTAssertTrue(MicHealth.isStalled(secondsSinceEngineStart: 3.5, secondsSinceLastBuffer: nil))
        XCTAssertFalse(MicHealth.isStalled(secondsSinceEngineStart: 60, secondsSinceLastBuffer: 1.0))
        XCTAssertTrue(MicHealth.isStalled(secondsSinceEngineStart: 60, secondsSinceLastBuffer: 3.2))
        // A just-rebuilt engine gets its own grace period.
        XCTAssertFalse(MicHealth.isStalled(secondsSinceEngineStart: 1.0, secondsSinceLastBuffer: 30))
    }

    func testRetryBackoffDoublesUpToFourSeconds() {
        XCTAssertEqual((1...6).map(MicHealth.retryDelay(afterFailedAttempts:)), [0.5, 1, 2, 4, 4, 4])
    }
}
