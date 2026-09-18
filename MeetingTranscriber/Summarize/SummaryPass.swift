import Foundation

/// The three LLM passes of a summary run and their generation settings.
enum SummaryPass: Sendable {
    case identifySpeakers
    case summary
    case title

    var localMaxTokens: Int {
        switch self {
        case .identifySpeakers: 200
        case .summary:          600
        case .title:            40
        }
    }

    var localTemperature: Float {
        switch self {
        case .identifySpeakers: 0.1
        case .summary:          0.3
        case .title:            0.2
        }
    }

    /// Output cap for cloud models. Reasoning models count their reasoning
    /// against it (a 40-token budget on gpt-6-astra was spent entirely on
    /// reasoning and returned no text), so these sit far above the local caps
    /// and only guard against runaway output.
    var cloudMaxCompletionTokens: Int {
        switch self {
        case .identifySpeakers: 4_000
        case .summary:          16_000
        case .title:            2_000
        }
    }
}
