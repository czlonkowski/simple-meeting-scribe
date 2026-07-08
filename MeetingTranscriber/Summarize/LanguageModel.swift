import Foundation

/// Local LLMs used for transcript summarization. Identified by their
/// HuggingFace repo ID. Text-only models load through MLXLLM's
/// `LLMModelFactory`; VLM-class models (Gemma 4 is `gemma4` / `gemma4_unified`)
/// load through `VLMModelFactory` — see `loadsViaVLMFactory`.
enum LanguageModel: String, CaseIterable, Codable, Identifiable, Hashable {
    case gemma4_12b_it_mlx_4bit = "mlx-community/gemma-4-12B-it-4bit"
    case qwen3_5_4b_mlx_8bit    = "mlx-community/Qwen3.5-4B-8bit"
    case qwen3_5_9b_mlx_4bit    = "mlx-community/Qwen3.5-9B-MLX-4bit"

    var id: String { rawValue }
    var repoID: String { rawValue }

    var displayName: String {
        switch self {
        case .gemma4_12b_it_mlx_4bit: "Gemma 4 12B 4-bit (Multilingual, ~7 GB — best quality)"
        case .qwen3_5_4b_mlx_8bit:    "Qwen3.5-4B 8-bit (English, ~1.5 GB)"
        case .qwen3_5_9b_mlx_4bit:    "Qwen3.5-9B (English, ~5 GB — better quality)"
        }
    }

    var approxDownloadGB: Double {
        switch self {
        case .gemma4_12b_it_mlx_4bit: 7.0
        case .qwen3_5_4b_mlx_8bit:    1.5
        case .qwen3_5_9b_mlx_4bit:    5.0
        }
    }

    var approxActiveMemoryGB: Double {
        switch self {
        case .gemma4_12b_it_mlx_4bit: 9.0
        case .qwen3_5_4b_mlx_8bit:    4.0
        case .qwen3_5_9b_mlx_4bit:    7.0
        }
    }

    var supportedLanguages: Set<TranscriptionLanguage> {
        switch self {
        // Gemma 4 is multilingual (140+ languages pretrained, Polish included).
        case .gemma4_12b_it_mlx_4bit: [.polish, .english]
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:    [.english]
        }
    }

    var shortName: String {
        switch self {
        case .gemma4_12b_it_mlx_4bit: "gemma4-12b-4bit"
        case .qwen3_5_4b_mlx_8bit:    "qwen3.5-4b-8bit"
        case .qwen3_5_9b_mlx_4bit:    "qwen3.5-9b"
        }
    }

    /// Qwen3 / Qwen3.5 ship a hybrid reasoning mode that emits `<think>…</think>`
    /// blocks before the answer. For summarization we only want the final
    /// answer, so we pass `enable_thinking=false` through the chat template
    /// context and strip leaked thought tags at display time. Gemma 4 has no
    /// such mode.
    var usesThinkingMode: Bool {
        switch self {
        case .gemma4_12b_it_mlx_4bit: false
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:    true
        }
    }

    /// Gemma 4 is a VLM-class architecture; we load it through `VLMModelFactory`.
    /// The 12B `gemma4_unified` variant is registered there since mlx-swift-lm
    /// 3.31.4. Text-only generation works fine on the resulting container — no
    /// image input, so the vision tower stays idle. Qwen text models load via
    /// the text-only `LLMModelFactory`.
    var loadsViaVLMFactory: Bool {
        switch self {
        case .gemma4_12b_it_mlx_4bit: true
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:    false
        }
    }
}
