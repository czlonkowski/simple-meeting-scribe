import XCTest
@testable import MeetingTranscriber

/// Opt-in run of the speaker correction against a real Azure OpenAI
/// deployment and a saved transcript. Skipped unless the variables are set
/// (xcodebuild forwards `TEST_RUNNER_`-prefixed ones):
///
///     TEST_RUNNER_AZURE_OPENAI_KEY=… TEST_RUNNER_AZURE_OPENAI_ENDPOINT=https://<resource>.openai.azure.com/ \
///     TEST_RUNNER_AZURE_OPENAI_DEPLOYMENT=gpt6luna TEST_RUNNER_AZURE_OPENAI_EFFORT=high \
///     TEST_RUNNER_SPEAKER_TEST_TRANSCRIPT=/path/transcript.json \
///     TEST_RUNNER_SPEAKER_TEST_OUTPUT=/path/corrected.json \
///       xcodebuild … test -only-testing:MeetingTranscriberTests/SpeakerCorrectionLiveTests
///
/// Writes the corrected transcript to SPEAKER_TEST_OUTPUT for scoring
/// against a reference transcript; the input file is never modified.
final class SpeakerCorrectionLiveTests: XCTestCase {

    func testCorrectsASavedTranscript() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["AZURE_OPENAI_KEY"], !key.isEmpty,
              let endpoint = env["AZURE_OPENAI_ENDPOINT"],
              let deploymentName = env["AZURE_OPENAI_DEPLOYMENT"],
              let input = env["SPEAKER_TEST_TRANSCRIPT"],
              let output = env["SPEAKER_TEST_OUTPUT"] else {
            throw XCTSkip("Set the AZURE_OPENAI_* and SPEAKER_TEST_* variables to run the live speaker correction")
        }
        let effort = env["AZURE_OPENAI_EFFORT"].flatMap(AzureDeployment.ReasoningEffort.init(rawValue:)) ?? .none
        let deployment = AzureDeployment(endpoint: endpoint, deployment: deploymentName,
                                         reasoningEffort: effort)
        let client = try AzureOpenAIClient(deployment: deployment, apiKey: key)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // as TranscriptStore saves it
        let doc = try decoder.decode(TranscriptDocument.self,
                                     from: Data(contentsOf: URL(fileURLWithPath: input)))
        XCTAssertTrue(SpeakerCorrection.isApplicable(to: doc))

        let outcome = try await SpeakerCorrection.run(doc: doc, client: client)
        XCTAssertEqual(outcome.succeededWindows, outcome.totalWindows)
        XCTAssertGreaterThan(outcome.changedLines, 0)

        var corrected = doc
        corrected.segments = outcome.segments
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(corrected).write(to: URL(fileURLWithPath: output))
    }
}
