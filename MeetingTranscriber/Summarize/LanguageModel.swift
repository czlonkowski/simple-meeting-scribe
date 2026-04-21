import Foundation

/// Local LLMs used for transcript summarization. Identified by their
/// HuggingFace repo ID — MLXLLM loads them through the standard
/// `LLMModelFactory.shared.loadContainer(configuration:)` pathway.
enum LanguageModel: String, CaseIterable, Codable, Identifiable, Hashable {
    case qwen3_5_4b_mlx_8bit      = "mlx-community/Qwen3.5-4B-8bit"
    case qwen3_5_9b_mlx_4bit      = "mlx-community/Qwen3.5-9B-MLX-4bit"
    case bielik_11b_v3_mlx_4bit   = "speakleash/Bielik-11B-v3.0-Instruct-MLX-4bit"
    case bielik_4_5b_v3_mlx_8bit  = "speakleash/Bielik-4.5B-v3.0-Instruct-MLX-8bit"

    var id: String { rawValue }
    var repoID: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen3_5_4b_mlx_8bit:     "Qwen3.5-4B 8-bit (English, ~1.5 GB)"
        case .qwen3_5_9b_mlx_4bit:     "Qwen3.5-9B (English, ~5 GB — better quality)"
        case .bielik_11b_v3_mlx_4bit:  "Bielik-11B v3.0 (Polish, ~6.5 GB)"
        case .bielik_4_5b_v3_mlx_8bit: "Bielik-4.5B v3.0 (Polish, ~4 GB)"
        }
    }

    var approxDownloadGB: Double {
        switch self {
        case .qwen3_5_4b_mlx_8bit:     1.5
        case .qwen3_5_9b_mlx_4bit:     5.0
        case .bielik_11b_v3_mlx_4bit:  6.5
        case .bielik_4_5b_v3_mlx_8bit: 4.0
        }
    }

    var approxActiveMemoryGB: Double {
        switch self {
        case .qwen3_5_4b_mlx_8bit:     4.0
        case .qwen3_5_9b_mlx_4bit:     7.0
        case .bielik_11b_v3_mlx_4bit:  8.0
        case .bielik_4_5b_v3_mlx_8bit: 5.0
        }
    }

    var supportedLanguages: Set<TranscriptionLanguage> {
        switch self {
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:     [.english]
        // Bielik officially supports 40+ languages; allow EN too.
        case .bielik_11b_v3_mlx_4bit,
             .bielik_4_5b_v3_mlx_8bit: [.polish, .english]
        }
    }

    var shortName: String {
        switch self {
        case .qwen3_5_4b_mlx_8bit:     "qwen3.5-4b-8bit"
        case .qwen3_5_9b_mlx_4bit:     "qwen3.5-9b"
        case .bielik_11b_v3_mlx_4bit:  "bielik-11b-v3"
        case .bielik_4_5b_v3_mlx_8bit: "bielik-4.5b-v3"
        }
    }

    /// Qwen3 / Qwen3.5 ship a hybrid reasoning mode that emits `<think>…</think>`
    /// tool-thought blocks before the answer. For summarization we only want the
    /// final answer, so we pass `enable_thinking=false` through the chat template
    /// context and also strip any leaked thought tags at display time.
    var usesThinkingMode: Bool {
        switch self {
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:     true
        case .bielik_11b_v3_mlx_4bit,
             .bielik_4_5b_v3_mlx_8bit: false
        }
    }
}
