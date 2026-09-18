import XCTest
@testable import MeetingTranscriber

/// Request/response contract with the Azure Speech fast-transcription API
/// (`enhancedMode` + MAI-Transcribe-2).
final class MAITranscribeEngineTests: XCTestCase {

    private func definition(diarize: Bool, phrases: [String]) throws -> [String: Any] {
        let data = try MAITranscribeEngine.definitionJSON(diarize: diarize, phrases: phrases)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDefinitionSelectsMAIModelWithCleanStyleAndWordTimestamps() throws {
        let def = try definition(diarize: false, phrases: [])
        let enhanced = try XCTUnwrap(def["enhancedMode"] as? [String: Any])
        XCTAssertEqual(enhanced["enabled"] as? Bool, true)
        XCTAssertEqual(enhanced["model"] as? String, "MAI-Transcribe-2")
        let options = try XCTUnwrap(enhanced["modelOptions"] as? [String: Any])
        XCTAssertEqual(options["timestamps"] as? String, "word")
        XCTAssertEqual(options["transcribeStyle"] as? String, "clean")
    }

    func testDefinitionLeavesLanguageToAutoDetection() throws {
        // A forced locale that doesn't match the speech makes MAI translate or
        // drop it (English picker + Polish speech → one English sentence), and
        // mixed PL/EN meetings need per-phrase detection anyway.
        XCTAssertNil(try definition(diarize: true, phrases: ["n8n"])["locales"])
    }

    func testDefinitionOmitsDiarizationAndPhraseListWhenUnused() throws {
        let def = try definition(diarize: false, phrases: [])
        XCTAssertNil(def["diarization"])
        XCTAssertNil(def["phraseList"])
    }

    func testDefinitionIncludesDiarizationAndPhrases() throws {
        let def = try definition(diarize: true, phrases: ["Contoso", "n8n"])
        XCTAssertEqual((def["diarization"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((def["phraseList"] as? [String: Any])?["phrases"] as? [String], ["Contoso", "n8n"])
    }

    func testDecodesPhrasesWithAndWithoutSpeaker() throws {
        let json = """
        {"durationMilliseconds": 4000,
         "combinedPhrases": [{"text": "Gotcha. That makes sense."}],
         "phrases": [
           {"speaker": 1, "offsetMilliseconds": 80, "durationMilliseconds": 339,
            "text": "Gotcha.", "locale": "en", "confidence": 0,
            "words": [{"text": "Gotcha.", "offsetMilliseconds": 80, "durationMilliseconds": 339}]},
           {"offsetMilliseconds": 800, "durationMilliseconds": 460,
            "text": "That makes sense.", "locale": "de"}
         ]}
        """
        let phrases = try MAITranscribeEngine.decode(Data(json.utf8))
        XCTAssertEqual(phrases.count, 2)
        XCTAssertEqual(phrases[0].speaker, 1)
        XCTAssertEqual(phrases[0].words?.first?.text, "Gotcha.")
        XCTAssertNil(phrases[1].speaker)
        XCTAssertNil(phrases[1].words)
        XCTAssertEqual(phrases[1].offsetMilliseconds, 800)
    }

    func testDiarizationFailuresAreRecognisedOnlyForDiarizedRequests() {
        for status in [408, 500, 503] {
            XCTAssertTrue(MAITranscribeEngine.isDiarizationFailure(status: status, diarize: true), "\(status)")
            XCTAssertFalse(MAITranscribeEngine.isDiarizationFailure(status: status, diarize: false), "\(status)")
        }
        XCTAssertFalse(MAITranscribeEngine.isDiarizationFailure(status: 401, diarize: true))
        XCTAssertFalse(MAITranscribeEngine.isDiarizationFailure(status: 400, diarize: true))
    }

    func testScribeFallbackIsAllowedForServiceFailuresButNotCredentials() {
        typealias E = MAITranscribeEngine.MAIError
        XCTAssertTrue(E.server(status: 500, message: nil).allowsScribeFallback)
        XCTAssertTrue(E.server(status: 429, message: nil).allowsScribeFallback)
        XCTAssertTrue(E.network(underlying: URLError(.timedOut)).allowsScribeFallback)
        XCTAssertTrue(E.badResponse.allowsScribeFallback)
        XCTAssertTrue(E.diarizationUnavailable(status: 503).allowsScribeFallback)
        XCTAssertFalse(E.unauthorized.allowsScribeFallback)
        XCTAssertFalse(E.missingAPIKey.allowsScribeFallback)
    }

    func testDiarizedTimeoutsAndDiarizationFailuresRetryWithoutDiarization() {
        typealias E = MAITranscribeEngine.MAIError
        let timeout = E.network(underlying: URLError(.timedOut))
        XCTAssertTrue(MAITranscribeEngine.shouldRetryWithoutDiarization(timeout, diarize: true))
        XCTAssertTrue(MAITranscribeEngine.shouldRetryWithoutDiarization(E.diarizationUnavailable(status: 408), diarize: true))
        // Without diarization the retry would be the identical request.
        XCTAssertFalse(MAITranscribeEngine.shouldRetryWithoutDiarization(timeout, diarize: false))
        // Other failures are not diarization-specific.
        XCTAssertFalse(MAITranscribeEngine.shouldRetryWithoutDiarization(E.network(underlying: URLError(.notConnectedToInternet)), diarize: true))
        XCTAssertFalse(MAITranscribeEngine.shouldRetryWithoutDiarization(E.unauthorized, diarize: true))
        XCTAssertFalse(MAITranscribeEngine.shouldRetryWithoutDiarization(E.server(status: 400, message: nil), diarize: true))
    }

    func testTranscribeURLIsBuiltFromTheResourceEndpoint() {
        let expected = "https://example-speech.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
        XCTAssertEqual(MAITranscribeEngine.transcribeURL(endpoint: "https://example-speech.cognitiveservices.azure.com/")?.absoluteString, expected)
        XCTAssertEqual(MAITranscribeEngine.transcribeURL(endpoint: " https://example-speech.cognitiveservices.azure.com ")?.absoluteString, expected)
    }

    func testTranscribeURLRejectsMissingOrNonHTTPSEndpoints() {
        XCTAssertNil(MAITranscribeEngine.transcribeURL(endpoint: ""))
        XCTAssertNil(MAITranscribeEngine.transcribeURL(endpoint: "example-speech"))
        XCTAssertNil(MAITranscribeEngine.transcribeURL(endpoint: "http://example-speech.cognitiveservices.azure.com"))
    }

    func testMissingEndpointIsAConfigurationErrorWithoutScribeFallback() {
        XCTAssertFalse(MAITranscribeEngine.MAIError.missingEndpoint.allowsScribeFallback)
    }
}
