import XCTest
@testable import MeetingTranscriber

final class SummaryModelTests: XCTestCase {

    func testLocalRawValueIsTheLegacyRepoID() {
        let model = SummaryModel.local(.qwen3_5_4b_mlx_8bit)
        XCTAssertEqual(model.rawValue, "mlx-community/Qwen3.5-4B-8bit")
        XCTAssertEqual(SummaryModel(rawValue: model.rawValue), model)
    }

    func testAzureRawValueRoundTrips() {
        let id = UUID()
        let model = SummaryModel.azure(id)
        XCTAssertEqual(model.rawValue, "azure:\(id.uuidString)")
        XCTAssertEqual(SummaryModel(rawValue: model.rawValue), model)
    }

    func testUnknownRawValuesDoNotDecode() {
        XCTAssertNil(SummaryModel(rawValue: "mlx-community/removed-model"))
        XCTAssertNil(SummaryModel(rawValue: "azure:not-a-uuid"))
        XCTAssertNil(SummaryModel(rawValue: ""))
    }

    // MARK: - Transcript JSON compatibility

    private func documentJSON(override: String?) throws -> Data {
        let doc = TranscriptDocument(
            id: "t1", title: "T", date: Date(timeIntervalSince1970: 0),
            duration: 60, language: .polish, modelShortName: "whisper",
            sourceKind: .live, speakers: [], segments: [], audioFileName: nil)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as! [String: Any]
        object["summaryModelOverride"] = override
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testLegacyLocalOverrideStillDecodes() throws {
        let data = try documentJSON(override: "mlx-community/gemma-4-12B-it-4bit")
        let doc = try JSONDecoder().decode(TranscriptDocument.self, from: data)
        XCTAssertEqual(doc.summaryModelOverride, .local(.gemma4_12b_it_mlx_4bit))
    }

    func testRemovedLocalOverrideDecodesAsNil() throws {
        let data = try documentJSON(override: "mlx-community/bielik-removed")
        let doc = try JSONDecoder().decode(TranscriptDocument.self, from: data)
        XCTAssertNil(doc.summaryModelOverride)
    }

    func testAzureOverrideRoundTripsThroughTranscriptJSON() throws {
        let id = UUID()
        var doc = try JSONDecoder().decode(TranscriptDocument.self, from: documentJSON(override: nil))
        doc.summaryModelOverride = .azure(id)
        let decoded = try JSONDecoder().decode(TranscriptDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(decoded.summaryModelOverride, .azure(id))
    }
}

final class AzureDeploymentTests: XCTestCase {

    func testChatCompletionsURLFromResourceEndpoint() {
        XCTAssertEqual(
            AzureDeployment.chatCompletionsURL(endpoint: "https://my-resource.openai.azure.com/")?.absoluteString,
            "https://my-resource.openai.azure.com/openai/v1/chat/completions")
        XCTAssertEqual(
            AzureDeployment.chatCompletionsURL(endpoint: "  https://Res.OpenAI.Azure.com  ")?.absoluteString,
            "https://res.openai.azure.com/openai/v1/chat/completions")
    }

    func testChatCompletionsURLFromPortalTargetURI() {
        let target = "https://res.cognitiveservices.azure.com/openai/deployments/gpt54/chat/completions?api-version=2025-01-01-preview"
        XCTAssertEqual(
            AzureDeployment.chatCompletionsURL(endpoint: target)?.absoluteString,
            "https://res.cognitiveservices.azure.com/openai/v1/chat/completions")
        XCTAssertEqual(
            AzureDeployment.chatCompletionsURL(endpoint: "https://res.openai.azure.com/openai/v1/")?.absoluteString,
            "https://res.openai.azure.com/openai/v1/chat/completions")
    }

    func testNonHTTPSEndpointsAreRejected() {
        XCTAssertNil(AzureDeployment.chatCompletionsURL(endpoint: "http://res.openai.azure.com/"))
        XCTAssertNil(AzureDeployment.chatCompletionsURL(endpoint: "res.openai.azure.com"))
        XCTAssertNil(AzureDeployment.chatCompletionsURL(endpoint: ""))
        XCTAssertNil(AzureDeployment.resourceKey(endpoint: "http://res.openai.azure.com/"))
    }

    func testResourceKeyIdentifiesTheResourceNotThePath() {
        let a = AzureDeployment.resourceKey(endpoint: "https://res.openai.azure.com/")
        let b = AzureDeployment.resourceKey(endpoint: "https://RES.openai.azure.com/openai/deployments/x/chat/completions")
        XCTAssertEqual(a, "https://res.openai.azure.com")
        XCTAssertEqual(a, b)
        XCTAssertEqual(AzureDeployment.resourceKey(endpoint: "https://gw.example.com:8443/x"),
                       "https://gw.example.com:8443")
    }

    func testDisplayNameFallsBackToDeployment() {
        var d = AzureDeployment(endpoint: "https://res.openai.azure.com/", deployment: "gpt6astra")
        XCTAssertEqual(d.displayName, "gpt6astra")
        d.name = "GPT-6 Astra"
        XCTAssertEqual(d.displayName, "GPT-6 Astra")
        XCTAssertEqual(d.shortName, "azure/gpt6astra")
    }
}

final class AzureOpenAIClientTests: XCTestCase {

    private func body(effort: AzureDeployment.ReasoningEffort) throws -> [String: Any] {
        let d = AzureDeployment(endpoint: "https://res.openai.azure.com/", deployment: "gpt6astra",
                                reasoningEffort: effort)
        let data = try AzureOpenAIClient.requestBody(deployment: d, prompt: "P", instructions: "S",
                                                     maxCompletionTokens: 16_000)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testRequestBodyUsesDeploymentAndCompletionCapWithoutTemperature() throws {
        let json = try body(effort: .none)
        XCTAssertEqual(json["model"] as? String, "gpt6astra")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_completion_tokens"] as? Int, 16_000)
        XCTAssertEqual(json["reasoning_effort"] as? String, "none")
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["max_tokens"])
        let messages = json["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages?.map { $0["content"] }, ["S", "P"])
    }

    func testModelDefaultEffortOmitsTheField() throws {
        XCTAssertNil(try body(effort: .modelDefault)["reasoning_effort"])
        XCTAssertEqual(try body(effort: .high)["reasoning_effort"] as? String, "high")
    }

    func testInitRejectsBadEndpointAndMissingKey() {
        let bad = AzureDeployment(endpoint: "http://res", deployment: "x")
        XCTAssertThrowsError(try AzureOpenAIClient(deployment: bad, apiKey: "k"))
        let good = AzureDeployment(endpoint: "https://res.openai.azure.com", deployment: "x")
        XCTAssertThrowsError(try AzureOpenAIClient(deployment: good, apiKey: ""))
        XCTAssertNoThrow(try AzureOpenAIClient(deployment: good, apiKey: "k"))
    }

    // MARK: - SSE lines as Azure sends them (captured 2026-09-18)

    func testMetadataChunksProduceNoEvents() throws {
        let promptFilter = #"data: {"choices":[],"created":0,"id":"","model":"","object":"","prompt_filter_results":[{"prompt_index":0,"content_filter_results":{"hate":{"filtered":false,"severity":"safe"}}}]}"#
        XCTAssertEqual(try AzureOpenAIClient.parse(line: promptFilter), [])
        let roleOnly = #"data: {"choices":[{"content_filter_results":{},"delta":{"content":"","refusal":null,"role":"assistant"},"finish_reason":null,"index":0,"logprobs":null}],"object":"chat.completion.chunk","usage":null}"#
        XCTAssertEqual(try AzureOpenAIClient.parse(line: roleOnly), [])
        let usage = #"data: {"choices":[],"id":"x","object":"chat.completion.chunk","usage":{"completion_tokens":9,"completion_tokens_details":{"reasoning_tokens":0}}}"#
        XCTAssertEqual(try AzureOpenAIClient.parse(line: usage), [])
        XCTAssertEqual(try AzureOpenAIClient.parse(line: "data: [DONE]"), [])
        XCTAssertEqual(try AzureOpenAIClient.parse(line: ": keep-alive"), [])
    }

    func testDeltaWithBenignFilterAnnotationYieldsText() throws {
        let line = #"data: {"choices":[{"content_filter_result":{"error":{"code":"content_filter_error","message":"The contents are not filtered"}},"content_filter_results":{},"delta":{"content":" Budget"},"finish_reason":null,"index":0,"logprobs":null}],"object":"chat.completion.chunk","usage":null}"#
        XCTAssertEqual(try AzureOpenAIClient.parse(line: line), [.text(" Budget")])
    }

    func testFinishReasonIsReported() throws {
        let line = #"data: {"choices":[{"content_filter_results":{},"delta":{},"finish_reason":"length","index":0,"logprobs":null}],"object":"chat.completion.chunk"}"#
        XCTAssertEqual(try AzureOpenAIClient.parse(line: line), [.finished(reason: "length")])
    }

    func testErrorObjectAndGarbageThrow() {
        XCTAssertThrowsError(try AzureOpenAIClient.parse(line: #"data: {"error":{"message":"Server overloaded"}}"#))
        XCTAssertThrowsError(try AzureOpenAIClient.parse(line: "data: {not json"))
    }
}

/// Opt-in round trip against a real Azure OpenAI deployment. Skipped unless
/// the variables are set (xcodebuild forwards `TEST_RUNNER_`-prefixed ones):
///
///     TEST_RUNNER_AZURE_OPENAI_ENDPOINT=https://<resource>.openai.azure.com/ \
///     TEST_RUNNER_AZURE_OPENAI_KEY=… TEST_RUNNER_AZURE_OPENAI_DEPLOYMENT=gpt6astra \
///       xcodebuild … test -only-testing:MeetingTranscriberTests/AzureOpenAIClientLiveTests
final class AzureOpenAIClientLiveTests: XCTestCase {

    private func client(effort: AzureDeployment.ReasoningEffort) throws -> AzureOpenAIClient {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["AZURE_OPENAI_ENDPOINT"], !endpoint.isEmpty,
              let key = env["AZURE_OPENAI_KEY"], !key.isEmpty,
              let deployment = env["AZURE_OPENAI_DEPLOYMENT"], !deployment.isEmpty else {
            throw XCTSkip("Set AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_KEY and AZURE_OPENAI_DEPLOYMENT to run live Azure OpenAI tests")
        }
        return try AzureOpenAIClient(
            deployment: AzureDeployment(endpoint: endpoint, deployment: deployment, reasoningEffort: effort),
            apiKey: key)
    }

    func testStreamsAPolishTitleWithReasoningOff() async throws {
        var text = ""
        for try await chunk in try client(effort: .none).stream(
            prompt: "Napisz tytuł (maks. 6 słów) dla spotkania o cięciach budżetu na Q3 i wstrzymaniu rekrutacji.",
            instructions: "Odpowiadasz wyłącznie tytułem.",
            maxCompletionTokens: SummaryPass.title.cloudMaxCompletionTokens) {
            text += chunk
        }
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testTinyCapWithDefaultReasoningReportsTheLimit() async throws {
        let stream = try client(effort: .modelDefault).stream(
            prompt: "Explain why the sky is blue in detail.", instructions: "Be thorough.",
            maxCompletionTokens: 16)
        do {
            for try await _ in stream {}
            XCTFail("Expected the output limit to be reported")
        } catch let error as AzureOpenAIClient.AzureOpenAIError {
            guard case .outputLimitReached = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testWrongKeyIsUnauthorized() async throws {
        let real = try client(effort: .none)
        let bad = try AzureOpenAIClient(deployment: real.deployment, apiKey: "not-a-key")
        do {
            _ = try await bad.test()
            XCTFail("Expected unauthorized")
        } catch let error as AzureOpenAIClient.AzureOpenAIError {
            guard case .unauthorized = error else { return XCTFail("Unexpected \(error)") }
        }
    }
}
