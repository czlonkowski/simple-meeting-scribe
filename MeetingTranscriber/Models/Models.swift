import Foundation
import SwiftUI

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
    // Cloud engine — not a WhisperKit folder; must never reach WhisperEngine.
    case scribeV2     = "elevenlabs-scribe-v2"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .largeV3Turbo: return "Whisper Large v3 Turbo (fast, ~632 MB)"
        case .largeV3:      return "Whisper Large v3 (best quality, ~626 MB)"
        case .scribeV2:     return "ElevenLabs Scribe v2 (cloud)"
        }
    }
    var shortName: String {
        switch self {
        case .largeV3Turbo: return "large-v3-turbo"
        case .largeV3:      return "large-v3"
        case .scribeV2:     return "scribe-v2"
        }
    }
    /// One-word label for segmented pickers.
    var compactName: String {
        switch self {
        case .largeV3Turbo: return "Turbo"
        case .largeV3:      return "Large"
        case .scribeV2:     return "Scribe"
        }
    }
    /// Cloud models are routed to `ScribeEngine`; local ones to `WhisperEngine`.
    var isCloud: Bool { self == .scribeV2 }
}

struct DetectedMeeting: Equatable, Hashable, Identifiable {
    let id: UUID = UUID()
    let title: String
    let platform: String
    let url: String
    let detectedAt: Date
    /// Bundle ID of the browser whose tab matched (e.g. Arc). Lets the screen
    /// recorder find the window hosting the meeting.
    var browserBundleID: String? = nil

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

/// Domain-term glossary entry, injected into the summarization system prompt
/// so the LLM can interpret proper nouns / jargon it can't infer from context.
/// Independent of `WordReplacement` (which rewrites Whisper output post-decoding).
struct GlossaryTerm: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var term: String              // e.g. "Estyl", "n8n"
    var definition: String        // short explanation, one line preferred
    var isEnabled: Bool = true
}

enum TagColor: String, Codable, CaseIterable, Hashable {
    case blue
    case green
    case orange
    case red
    case purple
    case pink
    case teal
    case yellow
    case gray

    var swiftUIColor: Color {
        switch self {
        case .blue:   return .blue
        case .green:  return .green
        case .orange: return .orange
        case .red:    return .red
        case .purple: return .purple
        case .pink:   return .pink
        case .teal:   return .teal
        case .yellow: return .yellow
        case .gray:   return .gray
        }
    }

    var displayName: String {
        rawValue.capitalized
    }
}

struct Tag: Codable, Identifiable, Hashable {
    var name: String
    var color: TagColor

    var id: String { name.lowercased() }
}

struct TranscriptDocument: Codable, Identifiable, Hashable {
    let id: String                // filename stem
    var title: String
    let date: Date                // when this was transcribed / created in-app
    /// When the meeting/recording actually happened. Populated for imported
    /// files from embedded media metadata (falling back to filesystem dates);
    /// nil for live recordings, where `date` already reflects the session.
    var recordedAt: Date? = nil
    var duration: TimeInterval
    let language: TranscriptionLanguage
    let modelShortName: String
    var sourceURL: String?        // meeting URL or imported file path
    var sourceKind: SourceKind
    var tags: [String] = []       // catalog tag names assigned to this recording
    var speakers: [SpeakerLabel]
    var segments: [TranscriptSegment]
    let audioFileName: String?    // basename of wav in the same dir
    // Screen recording (optional — only set when the meeting window was
    // captured). Video lives next to the audio stems in recordings/.
    var videoFileName: String? = nil      // basename of <base>.video.mp4
    var videoStartOffset: Double? = nil   // seconds video started after the mic stem

    // Summarization (optional — only set once the user runs one).
    var summary: String?
    var summaryModelShortName: String?
    var summaryGeneratedAt: Date?
    // Per-meeting override for the summarization model. nil = use the
    // language default from Settings.
    var summaryModelOverride: LanguageModel?

    /// Date to display and sort by: the real recording date when known,
    /// otherwise the transcription date.
    var displayDate: Date { recordedAt ?? date }

    enum SourceKind: String, Codable {
        case live
        case imported
    }
}

extension TranscriptDocument {
    /// Custom decoder that tolerates a `summaryModelOverride` referring to a
    /// model that no longer exists (e.g. a removed Bielik repo ID): it decodes
    /// to `nil` rather than throwing, so old transcripts still load. All other
    /// fields decode exactly as the synthesized initializer would.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        recordedAt = try c.decodeIfPresent(Date.self, forKey: .recordedAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        language = try c.decode(TranscriptionLanguage.self, forKey: .language)
        modelShortName = try c.decode(String.self, forKey: .modelShortName)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        sourceKind = try c.decode(SourceKind.self, forKey: .sourceKind)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        speakers = try c.decode([SpeakerLabel].self, forKey: .speakers)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        videoFileName = try c.decodeIfPresent(String.self, forKey: .videoFileName)
        videoStartOffset = try c.decodeIfPresent(Double.self, forKey: .videoStartOffset)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryModelShortName = try c.decodeIfPresent(String.self, forKey: .summaryModelShortName)
        summaryGeneratedAt = try c.decodeIfPresent(Date.self, forKey: .summaryGeneratedAt)
        // Lenient: present-but-unknown rawValue throws inside decodeIfPresent,
        // which `try?` turns into nil; absent key also yields nil.
        summaryModelOverride = (try? c.decodeIfPresent(LanguageModel.self, forKey: .summaryModelOverride)) ?? nil
    }
}
