import Foundation
import Observation

/// Who said a piece of live text. The live transcript only knows which
/// stream the audio came from: your mic, or the meeting's system audio.
enum LiveSpeaker: String, Sendable, Equatable {
    case me
    case others
}

/// One chunk of live text (about 11 seconds of one stream).
struct LiveSegment: Identifiable, Equatable, Sendable {
    /// Arrival order, starting at 1. Doubles as the MCP cursor.
    let id: Int
    let speaker: LiveSpeaker
    /// Seconds since the recording started.
    let start: TimeInterval
    let text: String
}

/// Consecutive segments of one speaker, joined for display and copying.
struct LiveTurn: Identifiable, Equatable {
    let id: Int
    let speaker: LiveSpeaker
    let start: TimeInterval
    let text: String
}

/// The draft transcript shown while recording. It is replaced by the normal
/// transcript once the recording stops and is transcribed; nothing from it
/// is saved.
@MainActor
@Observable
final class LiveTranscript {
    enum Status: Equatable {
        case off
        case loading
        case running
        case failed(String)
    }

    /// What is producing the text.
    enum Engine: Equatable {
        case azure
        case onDevice
        /// Azure is set up but failed, so Parakeet took over.
        case onDeviceFallback
    }

    private(set) var status: Status = .off
    private(set) var engine: Engine?
    /// Per speaker, the sentence being heard right now (Azure only). It may
    /// still change, so it is shown but never copied or served over MCP.
    private(set) var partial: [LiveSpeaker: String] = [:]
    /// Sorted by `start`.
    private(set) var segments: [LiveSegment] = []
    /// Start of the recording these segments belong to.
    private(set) var recordingStart: Date?
    private var nextID = 1

    /// Highest segment id so far; 0 when empty.
    var cursor: Int { nextID - 1 }

    /// Starts (or resumes) live text for a recording. Text from an earlier
    /// recording is cleared; text from this one is kept, so turning the
    /// live transcript off and on again mid-meeting adds to it.
    func begin(recordingStart: Date) {
        if self.recordingStart != recordingStart {
            segments = []
            nextID = 1
            self.recordingStart = recordingStart
        }
        status = .loading
        engine = nil
    }

    func setEngine(_ engine: Engine) {
        self.engine = engine
    }

    func markRunning() {
        if status == .loading { status = .running }
    }

    func fail(_ message: String) {
        status = .failed(message)
    }

    func end() {
        status = .off
        partial = [:]
    }

    func setPartial(_ text: String?, for speaker: LiveSpeaker) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        partial[speaker] = trimmed.isEmpty ? nil : trimmed
    }

    func clear() {
        segments = []
        nextID = 1
        recordingStart = nil
        partial = [:]
        if case .failed = status { status = .off }
    }

    func append(speaker: LiveSpeaker, start: TimeInterval, text: String) {
        partial[speaker] = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let segment = LiveSegment(id: nextID, speaker: speaker, start: max(0, start), text: trimmed)
        nextID += 1
        // The two streams report independently, so a segment can arrive
        // after a later one from the other stream.
        let index = segments.lastIndex { $0.start <= segment.start }.map { $0 + 1 } ?? 0
        segments.insert(segment, at: index)
    }
}

/// Pure formatting for the live transcript: turns, timestamps, markdown.
enum LiveTranscriptFormat {
    /// Joins consecutive segments of the same speaker into one turn.
    static func turns(_ segments: [LiveSegment]) -> [LiveTurn] {
        var result: [LiveTurn] = []
        for segment in segments {
            if let last = result.last, last.speaker == segment.speaker {
                result[result.count - 1] = LiveTurn(id: last.id,
                                                    speaker: last.speaker,
                                                    start: last.start,
                                                    text: last.text + " " + segment.text)
            } else {
                result.append(LiveTurn(id: segment.id,
                                       speaker: segment.speaker,
                                       start: segment.start,
                                       text: segment.text))
            }
        }
        return result
    }

    /// Segments that started in the last `seconds` before the newest one.
    static func recent(_ segments: [LiveSegment], seconds: TimeInterval) -> [LiveSegment] {
        guard let latest = segments.last?.start else { return [] }
        return segments.filter { $0.start >= latest - seconds }
    }

    static func markdown(_ segments: [LiveSegment], myName: String, othersName: String = "Others") -> String {
        turns(segments).map { turn in
            let name = turn.speaker == .me ? myName : othersName
            return "**[\(timestamp(turn.start))] \(name):** \(turn.text)"
        }
        .joined(separator: "\n\n")
    }

    /// "4:05" under an hour, "1:04:05" from an hour on.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3_600, m = (s % 3_600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    static func displayName(for userDisplayName: String) -> String {
        let trimmed = userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "You" : trimmed
    }
}
