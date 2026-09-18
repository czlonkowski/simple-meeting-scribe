import XCTest
@testable import MeetingTranscriber

/// Opt-in hardware test: records from the real mic while another process
/// reconfigures system audio (e.g. a browser opening Bluetooth headphones'
/// mic, which flips them to the call profile), and checks the mic keeps
/// delivering. Skipped unless MIC_LIVE_TEST=1 (xcodebuild forwards
/// `TEST_RUNNER_`-prefixed variables):
///
///     TEST_RUNNER_MIC_LIVE_TEST=1 \
///     TEST_RUNNER_MIC_LIVE_UID='<preferred input UID, optional>' \
///     TEST_RUNNER_MIC_LIVE_TRIGGER='<shell command that reconfigures audio>' \
///     TEST_RUNNER_MIC_LIVE_EXPECT_DEVICE='<name the mic should end on, optional>' \
///       xcodebuild … test -only-testing:MeetingTranscriberTests/AudioRecorderLiveTests
final class AudioRecorderLiveTests: XCTestCase {

    private final class SampleCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testMicKeepsDeliveringAcrossAnAudioConfigurationChange() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MIC_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set MIC_LIVE_TEST=1 to run the live microphone test")
        }
        let counter = SampleCounter()
        let recorder = AudioRecorder()
        recorder.preferredDeviceUID = env["MIC_LIVE_UID"]
        recorder.onSamples = { counter.add($0.count) }
        let started = Date()
        try await MainActor.run { try recorder.start() }

        try await Task.sleep(for: .seconds(3))
        let beforeTrigger = counter.total

        if let trigger = env["MIC_LIVE_TRIGGER"], !trigger.isEmpty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", trigger]
            try process.run()
        }

        // Samples delivered per 2-second window after the trigger (16 kHz mono).
        var windows: [Int] = []
        for _ in 0..<6 {
            let start = counter.total
            try await Task.sleep(for: .seconds(2))
            windows.append(counter.total - start)
        }
        let elapsed = Date().timeIntervalSince(started)
        let rebuilds = await MainActor.run { recorder.rebuildCount }
        let device = await MainActor.run { recorder.activeInputDeviceName() } ?? "?"
        await MainActor.run { recorder.stop() }
        let stemSeconds = Double(counter.total) / 16_000
        print("MIC_LIVE before=\(beforeTrigger) windows=\(windows) rebuilds=\(rebuilds) device=\(device) stem=\(stemSeconds)s elapsed=\(elapsed)s")

        XCTAssertGreaterThan(beforeTrigger, 16_000 * 2, "mic delivered nothing before the trigger")
        XCTAssertGreaterThan(windows.suffix(2).min() ?? 0, 16_000,
                             "mic stopped delivering after the configuration change: \(windows)")
        // Gaps are padded, so the stem keeps pace with the wall clock.
        XCTAssertEqual(stemSeconds, elapsed, accuracy: 0.6, "voice stem drifted off the timeline")
        XCTAssertLessThanOrEqual(rebuilds, 3, "configuration changes caused a rebuild storm")
        // Following the system default: a default-input switch must be followed.
        if let expected = env["MIC_LIVE_EXPECT_DEVICE"], !expected.isEmpty {
            XCTAssertTrue(device.contains(expected), "still capturing from \(device), expected \(expected)")
        }
    }
}
