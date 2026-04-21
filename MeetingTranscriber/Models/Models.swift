import Foundation

enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable, Hashable {
    case english = "en"
    case polish  = "pl"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .english: return "English"
        case .polish:  return "Polski"
        }
    }
    var flag: String {
        switch self {
        case .english: return "🇬🇧"
        case .polish:  return "🇵🇱"
        }
    }
}

enum WhisperModel: String, CaseIterable, Codable, Identifiable, Hashable {
    // WhisperKit prefixes these with "openai_whisper-" internally;
    // raw values must match folder suffixes in argmaxinc/whisperkit-coreml.
    // Using quantized 632MB/626MB variants for fast downloads (negligible WER diff).
    case largeV3Turbo = "large-v3-v20240930_turbo_632MB"
    case largeV3      = "large-v3-v20240930_626MB"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .largeV3Turbo: return "Whisper Large v3 Turbo (fast, ~632 MB)"
        case .largeV3:      return "Whisper Large v3 (best quality, ~626 MB)"
        }
    }
    var shortName: String {
        switch self {
        case .largeV3Turbo: return "large-v3-turbo"
        case .largeV3:      return "large-v3"
        }
    }
}

struct DetectedMeeting: Equatable, Hashable, Identifiable {
    let id: UUID = UUID()
    let title: String
    let platform: String
    let url: String
    let detectedAt: Date

    static func == (lhs: DetectedMeeting, rhs: DetectedMeeting) -> Bool {
        lhs.url == rhs.url
    }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    let start: Double   // seconds
    let end: Double     // seconds
    var speakerId: Int  // 0-based; -1 for unknown
    let text: String
}

struct SpeakerLabel: Codable, Hashable, Identifiable {
    let id: Int
    var name: String
}

struct WordReplacement: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var original: String          // may be comma-separated variants, e.g. "Anthropic, Enthropic"
    var replacement: String
    var isEnabled: Bool = true
}

struct TranscriptDocument: Codable, Identifiable, Hashable {
    let id: String                // filename stem
    var title: String
    let date: Date
    var duration: TimeInterval
    let language: TranscriptionLanguage
    let modelShortName: String
    var sourceURL: String?        // meeting URL or imported file path
    var sourceKind: SourceKind
    var speakers: [SpeakerLabel]
    var segments: [TranscriptSegment]
    let audioFileName: String?    // basename of wav in the same dir

    // Summarization (optional — only set once the user runs one).
    var summary: String?
    var actionItems: [String]?
    var summaryModelShortName: String?
    var summaryGeneratedAt: Date?

    enum SourceKind: String, Codable {
        case live
        case imported
    }
}
