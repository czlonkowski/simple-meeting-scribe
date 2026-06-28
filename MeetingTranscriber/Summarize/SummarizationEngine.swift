import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import OSLog
import Tokenizers

enum SummarizationError: Error, LocalizedError {
    case noActiveModel
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noActiveModel: "No summarization model is loaded."
        case .cancelled:     "Summarization was cancelled."
        }
    }
}

/// Owns at most one MLX ``ModelContainer`` at a time. Switching models
/// drops the previous one so unified memory doesn't balloon.
actor SummarizationEngine {

    private var activeModelID: String?
    private var container: ModelContainer?
    private var configured = false

    // MARK: - State

    func activeModelRepoID() -> String? { activeModelID }

    func unload() {
        container = nil
        activeModelID = nil
        // Give the unified-memory cache back to the system — without this
        // MLX can hold multiple GB of reusable buffers long after we're done.
        MLX.Memory.clearCache()
        Log.summary.notice("unload: cleared MLX cache, no model resident")
    }

    /// Cap MLX's memory usage so summarization doesn't push the whole system
    /// into swap. Called lazily on first load.
    private func configureMemoryBudgetOnce() {
        guard !configured else { return }
        configured = true
        // 16 GB cap on MLX allocations — generous headroom for the
        // summarization models (largest active footprint ~7 GB). On a 32 GB
        // M-series Mac this leaves ~16 GB for the OS, Whisper (CoreML/ANE),
        // browser, etc. memoryLimit is a soft recycle threshold, not a hard
        // ceiling, so brief spikes on long transcripts are tolerated.
        let memLimitBytes = 16 * 1024 * 1024 * 1024
        MLX.GPU.set(memoryLimit: memLimitBytes)
        // Keep the allocator cache tiny so memory is returned promptly.
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)   // 256 MB
        Log.summary.notice("memory budget: limit=\(memLimitBytes, privacy: .public) cache=256MB")
    }

    /// Drop MLX's reusable allocator cache without evicting the loaded model.
    /// Call this at idle points (after each summary finishes) to return RAM
    /// the KV cache + intermediate buffers would otherwise hold on to.
    func releaseCaches() {
        MLX.Memory.clearCache()
    }

    /// Load `model`'s container through the correct MLX factory. Gemma 4 is a
    /// VLM-class arch and must go through `VLMModelFactory`; Qwen text models
    /// go through `LLMModelFactory`. Both return an `MLXLMCommon.ModelContainer`
    /// that `ChatSession` drives identically for text-only generation.
    private func loadContainer(
        for model: LanguageModel,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> ModelContainer {
        let config = ModelConfiguration(id: model.repoID)
        if model.loadsViaVLMFactory {
            return try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: config,
                progressHandler: progress
            )
        } else {
            return try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: config,
                progressHandler: progress
            )
        }
    }

    // MARK: - Load / download

    /// Ensure `model` is resident. Drops any previously-loaded model first.
    /// The HuggingFace download runs on first call; subsequent calls hit the
    /// on-disk cache and resolve in a second or two.
    func ensureLoaded(
        _ model: LanguageModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        configureMemoryBudgetOnce()
        if activeModelID == model.repoID, container != nil { return }
        container = nil
        activeModelID = nil
        MLX.Memory.clearCache() // free the previous model's buffers before loading the next

        let c = try await loadContainer(for: model) { p in
            progress(p.fractionCompleted)
        }
        self.container = c
        self.activeModelID = model.repoID
    }

    /// Populate the HuggingFace cache without keeping the model resident.
    /// Used by Settings → Model Library's "Download" button so the user can
    /// pre-pull weights over a fast connection and get instant first
    /// summaries later.
    func prefetch(
        _ model: LanguageModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        configureMemoryBudgetOnce()
        Log.summary.notice("prefetch(\(model.shortName, privacy: .public)) — loading container")
        _ = try await loadContainer(for: model) { p in
            Log.summary.debug(
                "loadContainer progress fractionCompleted=\(p.fractionCompleted, privacy: .public) completed=\(p.completedUnitCount, privacy: .public) total=\(p.totalUnitCount, privacy: .public)"
            )
            progress(p.fractionCompleted)
        }
        Log.summary.notice("prefetch(\(model.shortName, privacy: .public)) — loadContainer returned")
        // Container drops out of scope here — memory freed, cache retained.
    }

    // MARK: - Streaming

    /// Stream tokens for a single-turn prompt with the given system instructions.
    /// Caller is responsible for cancelling the for-await loop to stop generation.
    ///
    /// `disableThinking` steers Qwen3 / Qwen3.5 hybrid-reasoning models to skip
    /// their `<think>…</think>` preamble by injecting `enable_thinking = false`
    /// into the chat template's Jinja context. Safe to pass for non-thinking
    /// models — the extra key is ignored by templates that don't reference it.
    func stream(
        prompt: String,
        instructions: String,
        maxTokens: Int = 800,
        temperature: Float = 0.3,
        disableThinking: Bool = false
    ) throws -> AsyncThrowingStream<String, Error> {
        guard let container else { throw SummarizationError.noActiveModel }
        let additional: [String: any Sendable]? = disableThinking
            ? ["enable_thinking": false]
            : nil
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: temperature
            ),
            additionalContext: additional
        )
        return session.streamResponse(to: prompt)
    }
}
