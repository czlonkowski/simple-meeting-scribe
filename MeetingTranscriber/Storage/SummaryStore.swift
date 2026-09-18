import Foundation

/// Persists summarization settings (default model per language, editable system
/// prompts, which models have been downloaded, and the registered Azure
/// deployments) via UserDefaults.
///
/// Cache inspection is a pragmatic heuristic — we record the "downloaded"
/// flag when `SummarizationEngine.prefetch` finishes successfully, and the
/// delete button walks the known HuggingFace cache roots.
enum SummaryStore {

    // MARK: - Keys

    private static let defaultModelPrefix    = "Summary.DefaultModel."     // + language raw value
    private static let systemPromptPrefix    = "Summary.SystemPrompt."     // + language raw value
    private static let downloadedIDsKey      = "Summary.DownloadedModelIDs"
    private static let userDisplayNameKey    = "Summary.UserDisplayName"
    private static let azureDeploymentsKey   = "Summary.AzureDeployments"

    // MARK: - Defaults

    static func defaultModel(for language: TranscriptionLanguage) -> LanguageModel {
        // Gemma 4 is the unified multilingual default for both languages.
        switch language {
        case .english: return .gemma4_12b_it_mlx_4bit
        case .polish:  return .gemma4_12b_it_mlx_4bit
        }
    }

    static func defaultSystemPrompt(for language: TranscriptionLanguage) -> String {
        switch language {
        case .english: return SummaryPrompts.defaultSystemEnglish
        case .polish:  return SummaryPrompts.defaultSystemPolish
        }
    }

    // MARK: - Load

    /// The saved default, or the built-in local one when nothing is saved or
    /// the saved Azure deployment no longer exists.
    static func loadDefaultModel(for language: TranscriptionLanguage) -> SummaryModel {
        let key = defaultModelPrefix + language.rawValue
        if let raw = UserDefaults.standard.string(forKey: key),
           let model = SummaryModel(rawValue: raw) {
            switch model {
            case .local:
                return model
            case .azure(let id) where loadAzureDeployments().contains(where: { $0.id == id }):
                return model
            case .azure:
                break
            }
        }
        return .local(defaultModel(for: language))
    }

    static func loadAzureDeployments() -> [AzureDeployment] {
        guard let data = UserDefaults.standard.data(forKey: azureDeploymentsKey) else { return [] }
        return (try? JSONDecoder().decode([AzureDeployment].self, from: data)) ?? []
    }

    static func loadSystemPrompt(for language: TranscriptionLanguage) -> String {
        let key = systemPromptPrefix + language.rawValue
        return UserDefaults.standard.string(forKey: key) ?? defaultSystemPrompt(for: language)
    }

    static func loadDownloadedIDs() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: downloadedIDsKey) ?? []
        // Filter to IDs that actually still have cached files — keeps us
        // honest if the user nuked the cache dir by hand.
        let fm = FileManager.default
        return Set(arr.filter { fm.fileExists(atPath: cacheDirectory(forRepoID: $0).path) })
    }

    // MARK: - Save

    static func saveDefaultModel(_ model: SummaryModel, for language: TranscriptionLanguage) {
        UserDefaults.standard.set(model.rawValue, forKey: defaultModelPrefix + language.rawValue)
    }

    static func saveSystemPrompt(_ text: String, for language: TranscriptionLanguage) {
        UserDefaults.standard.set(text, forKey: systemPromptPrefix + language.rawValue)
    }

    static func saveDownloadedIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: downloadedIDsKey)
    }

    static func saveAzureDeployments(_ deployments: [AzureDeployment]) {
        guard let data = try? JSONEncoder().encode(deployments) else { return }
        UserDefaults.standard.set(data, forKey: azureDeploymentsKey)
    }

    static func loadUserDisplayName() -> String {
        UserDefaults.standard.string(forKey: userDisplayNameKey) ?? ""
    }

    static func saveUserDisplayName(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: userDisplayNameKey)
    }

    // MARK: - Cache inspection / deletion

    /// HuggingFace `HubClient` (from swift-huggingface) stores weights under
    /// `~/Documents/huggingface/models/<org>/<repo>/` by default. We also
    /// probe the legacy `~/.cache/huggingface/hub/` path in case MLX or
    /// swift-transformers resolves there on some machines.
    static func cacheDirectory(forRepoID repoID: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent(repoID)
    }

    static func deleteCachedFiles(for model: LanguageModel) {
        let fm = FileManager.default
        let primary = cacheDirectory(forRepoID: model.repoID)
        try? fm.removeItem(at: primary)

        // Legacy HF hub layout fallback: models--<org>--<repo>
        let hubSlug = "models--" + model.repoID.replacingOccurrences(of: "/", with: "--")
        let legacy = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
            .appendingPathComponent(hubSlug)
        try? fm.removeItem(at: legacy)
    }

    static func directorySizeGB(for model: LanguageModel) -> Double? {
        let url = cacheDirectory(forRepoID: model.repoID)
        guard let size = try? FileManager.default.directorySize(url: url), size > 0 else { return nil }
        return Double(size) / 1_073_741_824.0
    }
}

private extension FileManager {
    /// Recursively sum file sizes under `url`. Returns nil if `url` doesn't exist.
    func directorySize(url: URL) throws -> UInt64 {
        var isDir: ObjCBool = false
        guard fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        let enumerator = enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var total: UInt64 = 0
        while let next = enumerator?.nextObject() as? URL {
            let values = try next.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true, let size = values.fileSize {
                total += UInt64(size)
            }
        }
        return total
    }
}
