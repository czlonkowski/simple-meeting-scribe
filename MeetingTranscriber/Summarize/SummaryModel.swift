import Foundation

/// A model the user can summarize with: one of the bundled local MLX models,
/// or an Azure OpenAI deployment registered in Settings → Summary.
///
/// Persisted as a single string so existing settings and transcripts keep
/// decoding: a local model is its HuggingFace repo ID (the historic
/// `LanguageModel` raw value), an Azure deployment is `azure:<uuid>`. Using
/// the deployment's UUID rather than its name keeps per-meeting choices
/// attached when the endpoint or deployment name is edited later.
enum SummaryModel: RawRepresentable, Codable, Hashable, Sendable {
    case local(LanguageModel)
    case azure(UUID)

    private static let azurePrefix = "azure:"

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.azurePrefix) {
            guard let id = UUID(uuidString: String(rawValue.dropFirst(Self.azurePrefix.count)))
            else { return nil }
            self = .azure(id)
        } else if let model = LanguageModel(rawValue: rawValue) {
            self = .local(model)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .local(let model): model.rawValue
        case .azure(let id):    Self.azurePrefix + id.uuidString
        }
    }
}
