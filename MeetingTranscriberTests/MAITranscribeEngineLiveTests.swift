import XCTest
@testable import MeetingTranscriber

/// Opt-in round trip against the real Azure endpoint. Skipped unless both
/// variables are set (xcodebuild forwards `TEST_RUNNER_`-prefixed ones):
///
///     TEST_RUNNER_AZURE_SPEECH_KEY=… TEST_RUNNER_AZURE_SPEECH_ENDPOINT=https://<resource>.cognitiveservices.azure.com/ \
///     TEST_RUNNER_MAI_TEST_AUDIO=/path/clip.wav \
///       xcodebuild … test -only-testing:MeetingTranscriberTests/MAITranscribeEngineLiveTests
///
/// The clip should be a short 16 kHz mono WAV with Polish speech from two people.
final class MAITranscribeEngineLiveTests: XCTestCase {

    private func inputs() throws -> (key: String, audio: URL, engine: MAITranscribeEngine) {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["AZURE_SPEECH_KEY"], !key.isEmpty,
              let url = MAITranscribeEngine.transcribeURL(endpoint: env["AZURE_SPEECH_ENDPOINT"] ?? ""),
              let path = env["MAI_TEST_AUDIO"], !path.isEmpty else {
            throw XCTSkip("Set AZURE_SPEECH_KEY, AZURE_SPEECH_ENDPOINT and MAI_TEST_AUDIO to run live MAI tests")
        }
        return (key, URL(fileURLWithPath: path), MAITranscribeEngine(transcribeURL: url))
    }

    func testDiarizedRequestReturnsSpeakersAndWordTimings() async throws {
        let (key, audio, engine) = try inputs()
        let phrases = try await engine.transcribe(
            url: audio, diarize: true, phrases: ["n8n"],
            apiKey: key, progress: { _, _ in })
        XCTAssertFalse(phrases.isEmpty)
        XCTAssertTrue(phrases.allSatisfy { $0.speaker != nil })
        XCTAssertFalse(MAISegmenter.spans(from: phrases).isEmpty)
        XCTAssertNotNil(phrases.first?.words?.first)
    }

    func testPlainChunkedRequestReturnsSpansWithoutSpeakers() async throws {
        let (key, audio, engine) = try inputs()
        let spans = try await engine.transcribeInChunks(
            url: audio, phrases: [], apiKey: key, progress: { _, _ in })
        XCTAssertFalse(spans.isEmpty)
        XCTAssertTrue(spans.allSatisfy { $0.speaker == nil })
    }

    func testWrongKeyIsReportedAsUnauthorized() async throws {
        let (_, audio, engine) = try inputs()
        do {
            _ = try await engine.transcribe(
                url: audio, diarize: false, phrases: [],
                apiKey: "not-a-key", progress: { _, _ in })
            XCTFail("expected unauthorized")
        } catch MAITranscribeEngine.MAIError.unauthorized {
            // expected
        }
    }
}
