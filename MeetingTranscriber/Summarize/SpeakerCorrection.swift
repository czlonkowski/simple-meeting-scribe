import Foundation
import OSLog

/// Re-attributes transcript lines to the right diarized speaker with an LLM
/// that reads the conversation.
///
/// Cloud diarization gets ~85% of speech right, but its errors come in runs:
/// a whole stretch of one person's speech filed under another speaker. The
/// text usually shows who really holds the floor (a presenter keeps walking
/// through slides, someone is addressed by name, a question gets an answer),
/// so the model reads the transcript in windows and returns the runs of lines
/// whose speaker is wrong, each with the cue that justifies it. Measured on a
/// meeting with the organizer's Teams transcript as reference: 85.2% → ~90.5%
/// on gpt-6-luna / gpt-6-sol / gpt-5.4, and only with reasoning on.
///
/// Speakers are only moved between existing diarized speakers; the mic
/// speaker ("You") is never moved in or out, since stem levels already decide
/// it reliably.
enum SpeakerCorrection {

    /// Lines the model may change per request, by start time.
    static let windowSeconds: Double = 15 * 60
    /// Read-only lines shown before and after each window, so a turn crossing
    /// a window edge keeps its context.
    static let contextSeconds: Double = 4 * 60
    /// Windows sent to Azure at the same time.
    static let maxConcurrentRequests = 3
    /// Reasoning models spend most of this on thinking; 8 000 was too little
    /// for gpt-6.1-sol on one 15-minute window.
    static let maxCompletionTokens = 24_000

    /// One request: `editable` lines may change, `context` lines are shown.
    struct Window: Equatable {
        let editable: ClosedRange<Int>
        let context: ClosedRange<Int>
    }

    /// A run of consecutive lines the model attributes to `speaker`.
    struct Run: Decodable, Equatable {
        let from: Int
        let to: Int
        let speaker: Int
        let cue: String?
    }

    // MARK: - Eligibility

    /// Speaker ids the correction must not move lines into or out of: the
    /// mic speaker of a live recording (always id 1, see TranscriptMerger).
    static func lockedSpeakerIDs(for doc: TranscriptDocument) -> Set<Int> {
        doc.sourceKind == .live ? [1] : []
    }

    /// Worth running when at least two movable speakers actually speak.
    static func isApplicable(to doc: TranscriptDocument) -> Bool {
        let locked = lockedSpeakerIDs(for: doc)
        let movable = Set(doc.segments.map(\.speakerId)).subtracting(locked).filter { $0 >= 0 }
        return movable.count >= 2
    }

    /// Reasoning is what makes this work: with `none`, gpt-6-luna barely
    /// changed anything (85.9%); from `low` up it reached 89.5–90.2%. Use the
    /// deployment's setting when it is at least `medium`; `modelDefault`
    /// stays unsent for models that reject the field.
    static func reasoningEffort(for configured: AzureDeployment.ReasoningEffort) -> AzureDeployment.ReasoningEffort {
        switch configured {
        case .none, .low: .medium
        case .modelDefault, .medium, .high: configured
        }
    }

    // MARK: - Windows

    static func windows(for segments: [TranscriptSegment]) -> [Window] {
        guard let last = segments.last else { return [] }
        var result: [Window] = []
        var windowStart: Double = 0
        while windowStart <= last.start {
            let windowEnd = windowStart + windowSeconds
            let editable = segments.indices.filter {
                segments[$0].start >= windowStart && segments[$0].start < windowEnd
            }
            if let first = editable.first, let lastEditable = editable.last {
                let context = segments.indices.filter {
                    segments[$0].start >= windowStart - contextSeconds
                        && segments[$0].start < windowEnd + contextSeconds
                }
                result.append(Window(editable: first...lastEditable,
                                     context: (context.first ?? first)...(context.last ?? lastEditable)))
            }
            windowStart = windowEnd
        }
        return result
    }

    // MARK: - Prompt

    static let instructions = """
    You correct speaker attribution in a meeting transcript produced by an automatic diarizer.
    Each line: L<id> [time] c<speaker>: text. The speaker is the diarizer's guess and is usually right (~85%).
    Known errors of this diarizer: it sometimes assigns a whole stretch of one person's speech (e.g. a long presentation or monologue) to another speaker, or flips single sentences inside someone's turn.
    Your job: find lines whose speaker is WRONG and say which existing speaker they belong to.
    Change a line ONLY with explicit textual evidence, for example:
    - continuity: the line continues the same sentence, argument or presentation of the previous speaker with no handoff (e.g. the presenter keeps describing slides);
    - the line addresses a person by name, so it is NOT that person speaking;
    - a question and its answer cannot be the same person; self-references ("as I said", "my analysis", "I added this slide") must match who was presenting.
    Speaker labels are placeholders or names from an imperfect earlier step; two speakers may share a name. Use them as hints only.
    If unsure, do not change. Only change lines in the EDITABLE range; other lines are context.
    Important: the diarizer's errors are usually whole RUNS of consecutive lines (e.g. 15 lines of one presenter's slide walkthrough labelled as a listener). First work out, in order, who is actually holding the floor (who presents, who asks, who answers), then report every run of lines whose speaker is wrong. Short backchannels ("Mhm", "Yes") inside someone else's turn usually belong to a listener, not the floor holder.
    Return only JSON: {"runs":[{"from":<first line int>,"to":<last line int>,"speaker":<speaker int>,"cue":"<short quote/reason>"}]}
    Every line in a run gets that speaker. Lines not covered keep their speaker. Return {"runs":[]} when nothing is wrong.
    """

    static func prompt(window: Window,
                       segments: [TranscriptSegment],
                       speakers: [SpeakerLabel],
                       locked: Set<Int>) -> String {
        let roster = speakers.map { speaker in
            let note = locked.contains(speaker.id)
                ? " (the recording user, on their own microphone; never move lines to or from c\(speaker.id))"
                : ""
            return "c\(speaker.id) = \(speaker.name)\(note)"
        }.joined(separator: "\n")
        let lines = window.context.map { i in
            let seg = segments[i]
            return "L\(i) [\(timestamp(seg.start))] c\(seg.speakerId): \(seg.text)"
        }.joined(separator: "\n")
        return """
        Speakers:
        \(roster)

        EDITABLE range: L\(window.editable.lowerBound)..L\(window.editable.upperBound)

        Transcript:
        \(lines)
        """
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    // MARK: - Parsing and applying

    /// The runs in a model reply. Tolerates code fences and prose around the
    /// JSON object; anything unparseable yields no runs.
    static func parseRuns(_ raw: String) -> [Run] {
        struct Reply: Decodable { let runs: [Run]? }
        guard let open = raw.firstIndex(of: "{"),
              let close = raw.lastIndex(of: "}"),
              open < close else { return [] }
        let json = Data(raw[open...close].utf8)
        return (try? JSONDecoder().decode(Reply.self, from: json))?.runs ?? []
    }

    /// New speaker per line index for the valid part of `runs`: lines inside
    /// the window's editable range, moving between existing unlocked
    /// speakers, with a cue. Everything else is ignored.
    static func reassignments(from runs: [Run],
                              window: Window,
                              segments: [TranscriptSegment],
                              speakerIDs: Set<Int>,
                              locked: Set<Int>) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for run in runs {
            guard let cue = run.cue, !cue.trimmingCharacters(in: .whitespaces).isEmpty,
                  speakerIDs.contains(run.speaker), !locked.contains(run.speaker),
                  run.from <= run.to else { continue }
            let lower = max(run.from, window.editable.lowerBound)
            let upper = min(run.to, window.editable.upperBound)
            guard lower <= upper else { continue }
            for i in lower...upper where !locked.contains(segments[i].speakerId)
                && segments[i].speakerId != run.speaker {
                out[i] = run.speaker
            }
        }
        return out
    }

    /// Segments with the reassignments applied. A moved segment remembers
    /// its diarized speaker in `diarizedSpeakerId`.
    static func apply(_ reassignments: [Int: Int], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var out = segments
        for (i, speaker) in reassignments where out.indices.contains(i) {
            out[i].diarizedSpeakerId = out[i].diarizedSpeakerId ?? out[i].speakerId
            out[i].speakerId = speaker
        }
        return out
    }

    // MARK: - Running

    /// Result of a run: the corrected segments and how many windows answered.
    struct Outcome {
        let segments: [TranscriptSegment]
        let changedLines: Int
        let succeededWindows: Int
        let totalWindows: Int
    }

    /// Runs every window against Azure. A failed window is logged and left
    /// as diarized; cancellation propagates.
    static func run(doc: TranscriptDocument,
                    client: AzureOpenAIClient) async throws -> Outcome {
        let segments = doc.segments
        let locked = lockedSpeakerIDs(for: doc)
        let speakerIDs = Set(doc.speakers.map(\.id))
        let windows = windows(for: segments)
        let effort = reasoningEffort(for: client.deployment.reasoningEffort)

        var reassigned: [Int: Int] = [:]
        var succeeded = 0
        try await withThrowingTaskGroup(of: [Int: Int]?.self) { group in
            var next = 0
            func addNext() {
                guard next < windows.count else { return }
                let window = windows[next]
                next += 1
                let prompt = prompt(window: window, segments: segments,
                                    speakers: doc.speakers, locked: locked)
                group.addTask {
                    do {
                        var reply = ""
                        for try await chunk in client.stream(prompt: prompt,
                                                             instructions: instructions,
                                                             maxCompletionTokens: maxCompletionTokens,
                                                             reasoningEffort: effort) {
                            reply += chunk
                        }
                        try Task.checkCancellation()
                        return reassignments(from: parseRuns(reply), window: window,
                                             segments: segments, speakerIDs: speakerIDs,
                                             locked: locked)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Log.summary.error("speaker correction: window L\(window.editable.lowerBound, privacy: .public)-L\(window.editable.upperBound, privacy: .public) failed — \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
            }
            for _ in 0..<maxConcurrentRequests { addNext() }
            while let result = try await group.next() {
                if let result {
                    succeeded += 1
                    reassigned.merge(result) { _, new in new }
                }
                addNext()
            }
        }
        Log.summary.notice("speaker correction: \(reassigned.count, privacy: .public) line(s) moved, \(succeeded, privacy: .public)/\(windows.count, privacy: .public) windows")
        return Outcome(segments: apply(reassigned, to: segments),
                       changedLines: reassigned.count,
                       succeededWindows: succeeded,
                       totalWindows: windows.count)
    }
}
