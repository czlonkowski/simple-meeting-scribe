import XCTest
@testable import MeetingTranscriber

/// Opt-in checks of the on-device FluidAudio paths (Parakeet transcription
/// and speaker separation) after a FluidAudio update. Skipped unless a clip
/// is given (xcodebuild forwards `TEST_RUNNER_`-prefixed variables):
///
///     TEST_RUNNER_FLUID_TEST_AUDIO=/path/clip.wav \
///       xcodebuild … test -only-testing:MeetingTranscriberTests/FluidAudioLiveTests
///
/// The clip should be a 16 kHz mono WAV of about 20 seconds with two
/// different voices taking turns. Models download on the first run.
final class FluidAudioLiveTests: XCTestCase {

    private func clip() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FLUID_TEST_AUDIO"], !path.isEmpty else {
            throw XCTSkip("Set FLUID_TEST_AUDIO to run the FluidAudio live tests")
        }
        return URL(fileURLWithPath: path)
    }

    func testParakeetReturnsTimedSegments() async throws {
        let segments = try await ParakeetEngine().transcribe(url: try clip(), progress: { _, _ in })
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start })
        print("PARAKEET:", segments.map(\.text).joined(separator: " | "))
    }

    func testDiarizationFindsMoreThanOneSpeaker() async throws {
        let segments = try await DiarizationEngine().diarize(wavURL: try clip(), progress: { _, _ in })
        XCTAssertFalse(segments.isEmpty)
        XCTAssertGreaterThan(Set(segments.map(\.speakerId)).count, 1)
        print("DIARIZATION:", segments.map { "\(Int($0.start))-\(Int($0.end))s:\($0.speakerId)" }.joined(separator: " "))
    }
}
