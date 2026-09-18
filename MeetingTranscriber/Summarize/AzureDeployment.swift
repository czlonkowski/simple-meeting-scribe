import Foundation

/// An Azure OpenAI (or Azure AI Foundry) model deployment registered in
/// Settings → Summary. The API key is not part of it: keys live in the
/// Keychain per resource (see `AzureOpenAIKeyStore`), so every deployment on
/// one resource shares a key.
struct AzureDeployment: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// Label shown in pickers; falls back to the deployment name when empty.
    var name: String = ""
    /// Resource endpoint as shown in the Azure portal, e.g.
    /// `https://<resource>.openai.azure.com/`. Only the scheme and host are
    /// used, so a pasted Target URI works too.
    var endpoint: String = ""
    /// Deployment name — sent as `model` on the v1 API.
    var deployment: String = ""
    var reasoningEffort: ReasoningEffort = .none

    /// `reasoning_effort` for reasoning models (gpt-5.x, gpt-6). They count
    /// reasoning against the output budget and think before the first token,
    /// so `none` gives the fastest summaries. Non-reasoning models reject
    /// the field — use `modelDefault` there to leave it out.
    enum ReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
        case modelDefault
        case none
        case low
        case medium
        case high

        var id: String { rawValue }

        /// Value of the `reasoning_effort` request field; nil omits it.
        var apiValue: String? { self == .modelDefault ? nil : rawValue }

        var displayName: String {
            switch self {
            case .modelDefault: "Model default (not sent)"
            case .none:         "None — fastest"
            case .low:          "Low"
            case .medium:       "Medium"
            case .high:         "High"
            }
        }
    }

    var displayName: String {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? deployment : label
    }

    /// Recorded as the summary's model on the transcript.
    var shortName: String { "azure/" + deployment }

    /// `https://<host>[:port]` of the endpoint — the identity of the Azure
    /// resource and the Keychain account of its API key.
    var resourceKey: String? { Self.resourceKey(endpoint: endpoint) }

    var chatCompletionsURL: URL? { Self.chatCompletionsURL(endpoint: endpoint) }

    static func resourceKey(endpoint: String) -> String? {
        guard let components = httpsComponents(endpoint) else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "https://\(components.host!)\(port)"
    }

    /// The v1 chat-completions URL of the endpoint's resource. The path is
    /// dropped so the portal's Target URI (`…/openai/deployments/<name>/…`)
    /// works as well as the bare resource endpoint. Nil for anything but an
    /// https URL.
    static func chatCompletionsURL(endpoint: String) -> URL? {
        guard var components = httpsComponents(endpoint) else { return nil }
        components.path = "/openai/v1/chat/completions"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func httpsComponents(_ endpoint: String) -> URLComponents? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URLComponents(string: trimmed),
              parsed.scheme?.lowercased() == "https",
              let host = parsed.host?.lowercased(), !host.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = parsed.port
        return components
    }
}
