import Foundation

/// Local LLMs used for transcript summarization. Identified by their
/// HuggingFace repo ID. Text-only models load through MLXLLM's
/// `LLMModelFactory`; VLM-class models (Gemma 4 is `gemma4`) load through
/// `VLMModelFactory` — see `loadsViaVLMFactory`.
enum LanguageModel: String, CaseIterable, Codable, Identifiable, Hashable {
    case gemma4_e4b_it_mlx_8bit = "mlx-community/gemma-4-e4b-it-8bit"
    case qwen3_5_4b_mlx_8bit    = "mlx-community/Qwen3.5-4B-8bit"
    case qwen3_5_9b_mlx_4bit    = "mlx-community/Qwen3.5-9B-MLX-4bit"

    var id: String { rawValue }
    var repoID: String { rawValue }

    var displayName: String {
        switch self {
        case .gemma4_e4b_it_mlx_8bit: "Gemma 4 E4B 8-bit (Multilingual, ~6 GB — fast)"
        case .qwen3_5_4b_mlx_8bit:    "Qwen3.5-4B 8-bit (English, ~1.5 GB)"
        case .qwen3_5_9b_mlx_4bit:    "Qwen3.5-9B (English, ~5 GB — better quality)"
        }
    }

    var approxDownloadGB: Double {
        switch self {
        case .gemma4_e4b_it_mlx_8bit: 6.0
        case .qwen3_5_4b_mlx_8bit:    1.5
        case .qwen3_5_9b_mlx_4bit:    5.0
        }
    }

    var approxActiveMemoryGB: Double {
        switch self {
        case .gemma4_e4b_it_mlx_8bit: 7.0
        case .qwen3_5_4b_mlx_8bit:    4.0
        case .qwen3_5_9b_mlx_4bit:    7.0
        }
    }

    var supportedLanguages: Set<TranscriptionLanguage> {
        switch self {
        // Gemma 4 is multilingual (140+ languages pretrained, Polish included).
        case .gemma4_e4b_it_mlx_8bit: [.polish, .english]
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:    [.english]
        }
    }

    var shortName: String {
        switch self {
        case .gemma4_e4b_it_mlx_8bit: "gemma4-e4b-8bit"
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
        case .gemma4_e4b_it_mlx_8bit: false
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:    true
        }
    }

    /// Gemma 4 is a VLM-class architecture (image-text-to-text); we load it
    /// through `VLMModelFactory`. Text-only generation works fine on the
    /// resulting container — no image input, so the vision tower stays idle.
    /// Qwen text models load via the text-only `LLMModelFactory`.
    var loadsViaVLMFactory: Bool {
        switch self {
        case .gemma4_e4b_it_mlx_8bit: true
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:    false
        }
    }
}
