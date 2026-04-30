import Foundation

/// Persists summarization settings (default model per language, editable system
/// prompts, and which models have been downloaded) via UserDefaults.
///
/// Cache inspection is a pragmatic heuristic — we record the "downloaded"
/// flag when `SummarizationEngine.prefetch` finishes successfully, and the
/// delete button walks the known HuggingFace cache roots.
enum SummaryStore {

    // MARK: - Keys

    private static let defaultModelPrefix    = "Summary.DefaultModel."     // + language raw value
    private static let systemPromptPrefix    = "Summary.SystemPrompt."     // + language raw value
    private static let downloadedIDsKey      = "Summary.DownloadedModelIDs"

    // MARK: - Defaults

    static func defaultModel(for language: TranscriptionLanguage) -> LanguageModel {
        switch language {
        case .english: return .qwen3_5_4b_mlx_8bit
        case .polish:  return .bielik_11b_v3_mlx_8bit
        }
    }

    static func defaultSystemPrompt(for language: TranscriptionLanguage) -> String {
        switch language {
        case .english: return SummaryPrompts.defaultSystemEnglish
        case .polish:  return SummaryPrompts.defaultSystemPolish
        }
    }

    // MARK: - Load

    static func loadDefaultModel(for language: TranscriptionLanguage) -> LanguageModel {
        let key = defaultModelPrefix + language.rawValue
        if let raw = UserDefaults.standard.string(forKey: key),
           let model = LanguageModel(rawValue: raw) {
            return model
        }
        return defaultModel(for: language)
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

    static func saveDefaultModel(_ model: LanguageModel, for language: TranscriptionLanguage) {
        UserDefaults.standard.set(model.rawValue, forKey: defaultModelPrefix + language.rawValue)
    }

    static func saveSystemPrompt(_ text: String, for language: TranscriptionLanguage) {
        UserDefaults.standard.set(text, forKey: systemPromptPrefix + language.rawValue)
    }

    static func saveDownloadedIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: downloadedIDsKey)
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
