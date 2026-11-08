import Foundation

enum WebhookError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case network(String)
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No webhook configured. Add one in Settings → Integrations."
        case .invalidURL:
            return "The webhook URL must start with https:// (http only for localhost)."
        case .network(let message):
            return "Webhook unreachable: \(message)"
        case .http(let status, let body):
            let detail = body.isEmpty ? "" : " — \(body)"
            return "Webhook returned HTTP \(status)\(detail)"
        }
    }
}

/// Where and how to POST. Built from `WebhookStore` at send time.
struct WebhookConfig: Equatable {
    var url: String
    var headerName: String
    var headerValue: String

    static func load() -> WebhookConfig {
        WebhookConfig(url: WebhookStore.loadURL(),
                      headerName: WebhookStore.loadHeaderName(),
                      headerValue: WebhookStore.loadHeaderValue())
    }

    var isConfigured: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// POSTs `WebhookEnvelope`s. One attempt, no retries: the user resends by
/// hand, and n8n upserts on the transcript id.
enum WebhookClient {
    static let timeout: TimeInterval = 60

    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func request(for envelope: WebhookEnvelope, config: WebhookConfig) throws -> URLRequest {
        try request(body: envelope.wireData(), config: config, timeout: timeout)
    }

    /// POST request with JSON body and the configured auth header.
    static func request(body: Data, config: WebhookConfig, timeout: TimeInterval) throws -> URLRequest {
        guard config.isConfigured else { throw WebhookError.notConfigured }
        guard let url = WebhookStore.validatedURL(config.url) else { throw WebhookError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let name = config.headerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = config.headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name.isEmpty ? WebhookStore.defaultHeaderName : name)
        }
        request.httpBody = body
        return request
    }

    static func send(_ envelope: WebhookEnvelope,
                     config: WebhookConfig = .load(),
                     session: URLSession? = nil) async throws {
        let request = try request(for: envelope, config: config)
        _ = try await perform(request, session: session)
        Log.webhook.notice("webhook: sent \(envelope.event.rawValue, privacy: .public) \(envelope.transcript?.id ?? "-", privacy: .public) (\(request.httpBody?.count ?? 0, privacy: .public) bytes)")
    }

    /// Runs the request; returns the body of a 2xx response.
    static func perform(_ request: URLRequest, session: URLSession? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (session ?? defaultSession).data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            Log.webhook.error("webhook: network error \(error.localizedDescription, privacy: .public)")
            throw WebhookError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw WebhookError.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Log.webhook.error("webhook: HTTP \(http.statusCode, privacy: .public) — \(body, privacy: .public)")
            throw WebhookError.http(status: http.statusCode, body: body)
        }
        return data
    }
}
