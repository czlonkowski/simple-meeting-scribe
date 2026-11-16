import Foundation

/// Metadata written next to a live recording's stems when it starts
/// (`<base>.meta.json` in recordings/). If the app dies before the transcript
/// is saved, this is what lets the recovered recording keep its meeting title
/// and language. Deleted once the transcript is saved.
struct RecordingSidecar: Codable, Hashable, Sendable {
    var title: String
    var language: TranscriptionLanguage
    var startedAt: Date
    var meetingTitle: String?
    var meetingPlatform: String?
    var meetingURL: String?
    /// Seconds the screen video started after the mic stem; set on a clean stop.
    var videoStartOffset: Double?
    /// Why the last transcription attempt failed, when it did.
    var lastError: String?
    var lastErrorAt: Date?

    /// The meeting the recording belonged to, rebuilt for the transcription
    /// pipeline (it takes the title and source URL from it).
    var meeting: DetectedMeeting? {
        guard let meetingTitle, let meetingURL else { return nil }
        return DetectedMeeting(title: meetingTitle,
                               platform: meetingPlatform ?? "",
                               url: meetingURL,
                               detectedAt: startedAt)
    }
}

/// A live recording whose stems are on disk but which has no transcript —
/// the app quit mid-recording, or transcription failed or never finished.
/// Found by scanning recordings/; never transcribed automatically.
struct PendingRecording: Identifiable, Hashable, Sendable {
    /// Stem base name, e.g. `2026-11-13_144226`.
    let id: String
    let voiceFileName: String
    let systemFileName: String?
    let videoFileName: String?
    let startedAt: Date
    /// Seconds of audio, estimated from the voice stem's file size (its header
    /// may be unfinalized, so it can't be trusted).
    let estimatedDuration: TimeInterval
    let sidecar: RecordingSidecar?

    var title: String {
        sidecar?.title ?? Self.fallbackTitle(for: startedAt)
    }

    static func fallbackTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "Recording — \(f.string(from: date))"
    }
}
