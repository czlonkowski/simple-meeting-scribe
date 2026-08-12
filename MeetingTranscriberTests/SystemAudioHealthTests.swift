import AVFoundation
import XCTest
@testable import MeetingTranscriber

/// The 2026-08-12 incident in one sentence: SCStream delivered buffers for
/// 3h08m while ~2h of them were digital silence, and nothing noticed. These
/// tests pin the ladder that is supposed to notice.
final class SystemAudioHealthTests: XCTestCase {

    private let rate: Double = 16_000
    /// One buffer's worth of frames at 16 kHz — roughly what SCK hands over.
    private let chunk = 1_600          // 0.1 s

    /// Feed `seconds` of audio through the health tracker, returning every
    /// action it asked for along the way.
    @discardableResult
    private func feed(_ health: inout SystemAudioHealth,
                      seconds: TimeInterval,
                      silent: Bool) -> [SystemAudioHealth.Action] {
        var actions: [SystemAudioHealth.Action] = []
        let buffers = Int((seconds * rate).rounded()) / chunk
        for _ in 0..<buffers {
            let action = health.ingest(frames: chunk, sampleRate: rate, isSilent: silent)
            if action != .none { actions.append(action) }
        }
        return actions
    }

    func testRealAudioNeverTriggersRecovery() {
        var health = SystemAudioHealth()
        XCTAssertEqual(feed(&health, seconds: 600, silent: false), [])
        XCTAssertEqual(health.status, .ok)
    }

    func testSilenceBelowThresholdIsLeftAlone() {
        // A normal pause in a meeting must not restart the capture.
        var health = SystemAudioHealth()
        XCTAssertEqual(feed(&health, seconds: 44, silent: true), [])
        XCTAssertFalse(health.isConcerning)
        XCTAssertEqual(health.status, .ok)
    }

    func testFilterRefreshComesFirstAndOnlyOnce() {
        var health = SystemAudioHealth()
        let actions = feed(&health, seconds: 60, silent: true)
        XCTAssertEqual(actions, [.refreshFilter],
                       "the cheap gapless recovery must fire first, and not repeat")
        XCTAssertTrue(health.isConcerning)
        XCTAssertEqual(health.silentSeconds, 60, accuracy: 0.01)
        XCTAssertNotEqual(health.status, .ok)
    }

    func testEscalatesToRestartWhenRefreshDoesNotHelp() {
        var health = SystemAudioHealth()
        let actions = feed(&health, seconds: 80, silent: true)
        XCTAssertEqual(actions, [.refreshFilter, .restartStream])
    }

    func testKeepsCyclingWhileStillDeaf() {
        // A stream that stays silent should be retried, not abandoned after one
        // pass — the 2026-08-12 tail was silent for 70 uninterrupted minutes.
        var health = SystemAudioHealth()
        let actions = feed(&health, seconds: 400, silent: true)
        XCTAssertEqual(actions.filter { $0 == .refreshFilter }.count, 4)
        XCTAssertEqual(actions.filter { $0 == .restartStream }.count, 4)
    }

    func testAttemptsAreCappedSoAQuietMeetingIsNotRestartedForever() {
        var health = SystemAudioHealth(maxRecoveryAttempts: 3)
        let actions = feed(&health, seconds: 3_600, silent: true)
        XCTAssertEqual(actions.count, 3)
    }

    func testAudioReturningClearsTheSilentRun() {
        var health = SystemAudioHealth()
        feed(&health, seconds: 60, silent: true)
        XCTAssertTrue(health.isConcerning)
        feed(&health, seconds: 1, silent: false)
        XCTAssertFalse(health.isConcerning)
        XCTAssertEqual(health.silentSeconds, 0)
    }

    func testSustainedAudioRestoresTheAttemptBudget() {
        // The incident had two separate drops an hour apart; the second must
        // still get a full budget.
        var health = SystemAudioHealth(maxRecoveryAttempts: 2)
        feed(&health, seconds: 200, silent: true)
        XCTAssertEqual(health.recoveryAttempts, 2, "budget spent on the first drop")

        feed(&health, seconds: 90, silent: false)
        XCTAssertEqual(health.recoveryAttempts, 0, "sustained real audio proves recovery worked")

        let second = feed(&health, seconds: 80, silent: true)
        XCTAssertEqual(second, [.refreshFilter, .restartStream])
    }

    func testBriefAudioFlickerDoesNotRestoreTheBudget() {
        // One stray non-zero buffer must not hand back a fresh set of restarts.
        var health = SystemAudioHealth(maxRecoveryAttempts: 2)
        feed(&health, seconds: 200, silent: true)
        feed(&health, seconds: 0.5, silent: false)
        XCTAssertEqual(health.recoveryAttempts, 2)
        XCTAssertEqual(feed(&health, seconds: 200, silent: true), [])
    }

    func testEmptyOrInvalidBuffersAreIgnored() {
        var health = SystemAudioHealth()
        XCTAssertEqual(health.ingest(frames: 0, sampleRate: rate, isSilent: true), .none)
        XCTAssertEqual(health.ingest(frames: chunk, sampleRate: 0, isSilent: true), .none)
        XCTAssertEqual(health.silentSeconds, 0)
    }
}

/// `SystemStemAnalyzer` decides whether a saved recording gets flagged as a
/// partial capture, so its arithmetic needs to be right on real WAV files.
final class SystemStemAnalyzerTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemStemAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL { try? FileManager.default.removeItem(at: directoryURL) }
        directoryURL = nil
    }

    /// Write a 16 kHz mono WAV whose first `silentSeconds` are exact zeros and
    /// whose remainder is a tone — the shape of the broken recording.
    private func makeStem(silentSeconds: Int, toneSeconds: Int) throws -> URL {
        let url = directoryURL.appendingPathComponent("stem-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        func write(_ seconds: Int, tone: Bool) throws {
            guard seconds > 0 else { return }
            let frames = AVAudioFrameCount(seconds * 16_000)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
            buf.frameLength = frames
            if let ch = buf.floatChannelData?[0] {
                for i in 0..<Int(frames) {
                    ch[i] = tone ? sin(Float(i) * 0.05) * 0.5 : 0
                }
            }
            try file.write(from: buf)
        }
        try write(silentSeconds, tone: false)
        try write(toneSeconds, tone: true)
        return url
    }

    func testAllSilentStemReportsFullySilent() throws {
        let url = try makeStem(silentSeconds: 10, toneSeconds: 0)
        XCTAssertEqual(try XCTUnwrap(SystemStemAnalyzer.silentFraction(of: url)), 1.0, accuracy: 0.001)
    }

    func testHealthyStemReportsAlmostNoSilence() throws {
        let url = try makeStem(silentSeconds: 0, toneSeconds: 10)
        // A sine crosses zero, so a few exact zeros are expected — but nowhere
        // near the partial-capture bar.
        let fraction = try XCTUnwrap(SystemStemAnalyzer.silentFraction(of: url))
        XCTAssertLessThan(fraction, 0.01)
    }

    func testMixedStemReportsTheSilentShare() throws {
        let url = try makeStem(silentSeconds: 30, toneSeconds: 10)
        XCTAssertEqual(try XCTUnwrap(SystemStemAnalyzer.silentFraction(of: url)), 0.75, accuracy: 0.01)
    }

    func testMissingFileReportsNothingRatherThanZero() {
        let missing = directoryURL.appendingPathComponent("nope.wav")
        XCTAssertNil(SystemStemAnalyzer.silentFraction(of: missing))
    }
}
