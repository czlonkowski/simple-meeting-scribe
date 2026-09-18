import Foundation
import OSLog

/// Streams chat completions from an Azure OpenAI deployment over the v1 API
/// (`<resource>/openai/v1/chat/completions`, deployment name as `model`).
///
/// Temperature is never sent: gpt-5.5 and newer reject anything but the
/// default. Output is capped with `max_completion_tokens` (gpt-5.x rejects
/// `max_tokens`).
struct AzureOpenAIClient: Sendable {
    let deployment: AzureDeployment
    let url: URL
    private let apiKey: String

    enum AzureOpenAIError: LocalizedError {
        case invalidEndpoint(deployment: String)
        case missingAPIKey(deployment: String)
        case deploymentRemoved
        case unauthorized
        case deploymentNotFound(String)
        case rateLimited
        case server(status: Int, message: String?)
        case network(underlying: Error)
        case contentFiltered
        case outputLimitReached
        case emptyResponse
        case incompleteResponse
        case badResponse

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint(let name):
                return "The Azure endpoint of \(name) is not an https URL. Fix it in Settings → Summary."
            case .missingAPIKey(let name):
                return "No API key is stored for the Azure resource of \(name). Add it in Settings → Summary."
            case .deploymentRemoved:
                return "The Azure deployment chosen for this meeting was removed from Settings. Pick another model below the Summarize button."
            case .unauthorized:
                return "Azure rejected the API key. Check it in Settings → Summary."
            case .deploymentNotFound(let name):
                return "Azure has no deployment named \"\(name)\" on this resource. Check the deployment name in Settings → Summary."
            case .rateLimited:
                return "Azure is rate-limiting this deployment (HTTP 429). Try again in a minute."
            case .server(let status, let message):
                let detail = message.map { ": \($0)" } ?? ""
                return "Azure OpenAI returned HTTP \(status)\(detail)"
            case .network(let underlying):
                return "Could not reach Azure OpenAI: \(underlying.localizedDescription)"
            case .contentFiltered:
                return "Azure's content filter stopped the response."
            case .outputLimitReached:
                return "The model hit the output limit before finishing. Try a lower reasoning effort in Settings → Summary."
            case .emptyResponse:
                return "The model returned no text."
            case .incompleteResponse:
                return "The Azure response ended before the model finished."
            case .badResponse:
                return "Azure OpenAI returned an unexpected response."
            }
        }
    }

    init(deployment: AzureDeployment, apiKey: String) throws {
        guard let url = deployment.chatCompletionsURL else {
            throw AzureOpenAIError.invalidEndpoint(deployment: deployment.displayName)
        }
        guard !apiKey.isEmpty else {
            throw AzureOpenAIError.missingAPIKey(deployment: deployment.displayName)
        }
        self.deployment = deployment
        self.url = url
        self.apiKey = apiKey
    }

    // MARK: - Streaming

    /// Stream the reply to a single-turn prompt with the given system
    /// instructions. Cancelling the consuming loop cancels the request.
    func stream(
        prompt: String,
        instructions: String,
        maxCompletionTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(prompt: prompt, instructions: instructions,
                                      maxCompletionTokens: maxCompletionTokens)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let deploymentName = deployment.deployment
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(request, deploymentName: deploymentName) { text in
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Send one tiny request to check the endpoint, key and deployment.
    /// Returns the model reply.
    func test() async throws -> String {
        var reply = ""
        for try await chunk in stream(prompt: "Reply with the single word OK.",
                                      instructions: "You are a connectivity check.",
                                      maxCompletionTokens: 2_000) {
            reply += chunk
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Request

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let stream = true
        let maxCompletionTokens: Int
        let reasoningEffort: String?
    }

    static func requestBody(deployment: AzureDeployment,
                            prompt: String,
                            instructions: String,
                            maxCompletionTokens: Int) throws -> Data {
        let body = ChatRequest(
            model: deployment.deployment,
            messages: [.init(role: "system", content: instructions),
                       .init(role: "user", content: prompt)],
            maxCompletionTokens: maxCompletionTokens,
            reasoningEffort: deployment.reasoningEffort.apiValue
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(body)
    }

    private func makeRequest(prompt: String,
                             instructions: String,
                             maxCompletionTokens: Int) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try Self.requestBody(deployment: deployment, prompt: prompt,
                                                instructions: instructions,
                                                maxCompletionTokens: maxCompletionTokens)
        return request
    }

    // MARK: - Transport

    /// Retries for throttling and transient server errors. They only happen
    /// before the first token, so a retry never duplicates streamed text.
    private static let maxRetries = 2
    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Idle time between bytes: reasoning at high effort over a long
        // transcript can take minutes before the first token.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private static func run(_ request: URLRequest,
                            deploymentName: String,
                            onText: (String) -> Void) async throws {
        var attempt = 0
        while true {
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw AzureOpenAIError.network(underlying: error)
            }
            guard let http = response as? HTTPURLResponse else { throw AzureOpenAIError.badResponse }

            guard http.statusCode == 200 else {
                let body = try await collect(bytes)
                Log.summary.error("azure: \(deploymentName, privacy: .public) HTTP \(http.statusCode, privacy: .public) — \(String(data: body, encoding: .utf8) ?? "<binary>", privacy: .public)")
                if retryableStatuses.contains(http.statusCode), attempt < maxRetries {
                    attempt += 1
                    let delay = retryDelay(http, attempt: attempt)
                    Log.summary.notice("azure: retry \(attempt, privacy: .public) in \(delay, privacy: .public)s")
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw failure(status: http.statusCode, body: body, deploymentName: deploymentName)
            }

            var finishReason: String?
            var producedText = false
            do {
                for try await line in bytes.lines {
                    for event in try parse(line: line) {
                        switch event {
                        case .text(let text):
                            producedText = true
                            onText(text)
                        case .finished(let reason):
                            finishReason = reason
                        }
                    }
                }
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                throw AzureOpenAIError.network(underlying: error)
            }
            try Task.checkCancellation()
            Log.summary.notice("azure: \(deploymentName, privacy: .public) finished reason=\(finishReason ?? "<none>", privacy: .public)")

            switch finishReason {
            case "stop":           break
            case "length":         throw AzureOpenAIError.outputLimitReached
            case "content_filter": throw AzureOpenAIError.contentFiltered
            case nil:              throw AzureOpenAIError.incompleteResponse
            default:               break
            }
            if !producedText { throw AzureOpenAIError.emptyResponse }
            return
        }
    }

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 64 * 1024 { break }
        }
        return data
    }

    /// `Retry-After` when Azure sends one (capped), exponential otherwise.
    private static func retryDelay(_ response: HTTPURLResponse, attempt: Int) -> Double {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header), seconds > 0 {
            return min(seconds, 30)
        }
        return pow(2, Double(attempt))
    }

    private static func failure(status: Int, body: Data, deploymentName: String) -> AzureOpenAIError {
        let detail = errorDetail(from: body)
        switch status {
        case 401, 403: return .unauthorized
        case 404 where detail.code == "DeploymentNotFound": return .deploymentNotFound(deploymentName)
        case 429:      return .rateLimited
        default:       return .server(status: status, message: detail.message)
        }
    }

    private static func errorDetail(from body: Data) -> (code: String?, message: String?) {
        struct Envelope: Decodable {
            struct Detail: Decodable {
                let code: String?
                let message: String?
            }
            let error: Detail?
        }
        guard let error = (try? JSONDecoder().decode(Envelope.self, from: body))?.error else {
            return (nil, nil)
        }
        return (error.code, error.message)
    }

    // MARK: - Server-sent events

    enum StreamEvent: Equatable {
        case text(String)
        case finished(reason: String)
    }

    /// Parse one server-sent-events line. Metadata chunks (prompt filter
    /// results, the trailing usage chunk, content-filter annotations on
    /// deltas) produce no events; an `error` object mid-stream throws.
    static func parse(line: String) throws -> [StreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty else { return [] }

        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
                let finishReason: String?
            }
            struct StreamError: Decodable { let message: String? }
            let choices: [Choice]?
            let error: StreamError?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let chunk = try? decoder.decode(Chunk.self, from: Data(payload.utf8)) else {
            throw AzureOpenAIError.badResponse
        }
        if let error = chunk.error {
            throw AzureOpenAIError.server(status: 200, message: error.message)
        }
        var events: [StreamEvent] = []
        for choice in chunk.choices ?? [] {
            if let content = choice.delta?.content, !content.isEmpty {
                events.append(.text(content))
            }
            if let reason = choice.finishReason {
                events.append(.finished(reason: reason))
            }
        }
        return events
    }
}

/// Refuses HTTP redirects so the `api-key` header is only ever sent to the
/// configured resource.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
