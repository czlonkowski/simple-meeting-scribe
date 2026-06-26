import Foundation

enum TranscriptMerger {

    /// Merge transcription of the mic stem ("You") with transcription of the
    /// system-audio stem ("Remote"). System-audio diarization optionally
    /// subdivides remote audio into Remote 1, Remote 2, …
    ///
    /// All segments are interleaved by start timestamp.
    static func mergeStems(voice: [WhisperSegment],
                           system: [WhisperSegment],
                           systemDiarization: [DiarizedSegment]) -> (segments: [TranscriptSegment],
                                                                     speakers: [SpeakerLabel]) {
        // ---- Assign speaker ids ----
        //   1           → You (voice stem)
        //   2..N        → Remote 1..(N-1) (system stem, from diarization)
        //
        // If system diarization gave us multiple distinct speakers we
        // expose them separately; otherwise everything from system audio
        // is just "Remote".

        var out: [TranscriptSegment] = []
        var speakers: [SpeakerLabel] = [SpeakerLabel(id: 1, name: "You")]

        for seg in voice {
            out.append(TranscriptSegment(start: seg.start,
                                         end: seg.end,
                                         speakerId: 1,
                                         text: seg.text))
        }

        if !system.isEmpty {
            // Build remote-speaker mapping from diarization.
            var remap: [Int: Int] = [:]
            var nextRemoteIndex = 2

            func remoteLabel(for rawID: Int) -> Int {
                if let existing = remap[rawID] { return existing }
                let idx = nextRemoteIndex
                remap[rawID] = idx
                nextRemoteIndex += 1
                return idx
            }

            for seg in system {
                let rawID = bestRawSpeakerID(for: seg, in: systemDiarization)
                           ?? nearestRawSpeakerID(to: seg, in: systemDiarization)
                let remoteID = rawID.map(remoteLabel(for:)) ?? 2
                _ = remoteLabel(for: rawID ?? -1) // ensure id exists
                out.append(TranscriptSegment(start: seg.start,
                                             end: seg.end,
                                             speakerId: remoteID,
                                             text: seg.text))
            }

            let remoteCount = max(1, remap.count)
            if remoteCount == 1 {
                speakers.append(SpeakerLabel(id: 2, name: "Remote"))
            } else {
                let sortedRemote = remap.values.sorted()
                for (offset, id) in sortedRemote.enumerated() {
                    speakers.append(SpeakerLabel(id: id, name: "Remote \(offset + 1)"))
                }
            }
        }

        // Interleave everything by start time.
        out.sort { $0.start < $1.start }
        return (out, speakers)
    }

    /// Map a single diarized transcription (the combined-mix cloud path) to
    /// app speakers. `diarization` is parallel to `segments` (one entry per
    /// segment). `voiceActivity` — speech intervals from the mic stem — picks
    /// out which diarized speaker is "You"; the rest become "Remote …" as in
    /// `mergeStems`. With no usable mic activity (e.g. imported files) the
    /// speakers are labeled "Speaker 1..N".
    static func mapDiarizedSingle(segments: [WhisperSegment],
                                  diarization: [DiarizedSegment],
                                  voiceActivity: [(start: Double, end: Double)])
        -> (segments: [TranscriptSegment], speakers: [SpeakerLabel]) {

        guard !segments.isEmpty else { return ([], []) }
        guard segments.count == diarization.count else {
            // No per-segment speaker info — single anonymous speaker.
            let segs = segments.map {
                TranscriptSegment(start: $0.start, end: $0.end, speakerId: 1, text: $0.text)
            }
            return (segs, [SpeakerLabel(id: 1, name: "Speaker 1")])
        }

        // Per raw speaker: total speech time and overlap with mic activity.
        var speechDur: [Int: Double] = [:]
        var micOverlap: [Int: Double] = [:]
        var firstSeen: [Int: Double] = [:]
        for d in diarization {
            speechDur[d.speakerId, default: 0] += d.end - d.start
            if firstSeen[d.speakerId] == nil { firstSeen[d.speakerId] = d.start }
            for v in voiceActivity {
                micOverlap[d.speakerId, default: 0]
                    += max(0, min(d.end, v.end) - max(d.start, v.start))
            }
        }

        // "You" = the speaker whose speech best coincides with mic activity.
        // Requires a meaningful match so a silent user doesn't grab the label.
        let youRawID: Int? = speechDur.keys
            .map { id -> (id: Int, overlap: Double, ratio: Double) in
                let overlap = micOverlap[id] ?? 0
                return (id, overlap, overlap / max(speechDur[id] ?? 0, 0.001))
            }
            .filter { $0.overlap >= 2.0 && $0.ratio >= 0.4 }
            .max(by: { $0.ratio < $1.ratio })?.id

        // Assign app ids in order of first appearance.
        let rawInOrder = firstSeen.sorted { $0.value < $1.value }.map(\.key)
        var idMap: [Int: Int] = [:]
        var speakers: [SpeakerLabel] = []
        if let you = youRawID {
            idMap[you] = 1
            speakers.append(SpeakerLabel(id: 1, name: "You"))
            let remotes = rawInOrder.filter { $0 != you }
            for (offset, raw) in remotes.enumerated() {
                idMap[raw] = offset + 2
                speakers.append(SpeakerLabel(id: offset + 2,
                                             name: remotes.count == 1 ? "Remote" : "Remote \(offset + 1)"))
            }
        } else {
            for (offset, raw) in rawInOrder.enumerated() {
                idMap[raw] = offset + 1
                speakers.append(SpeakerLabel(id: offset + 1, name: "Speaker \(offset + 1)"))
            }
        }

        let segs = zip(segments, diarization).map { seg, d in
            TranscriptSegment(start: seg.start, end: seg.end,
                              speakerId: idMap[d.speakerId] ?? -1,
                              text: seg.text)
        }
        return (segs, speakers)
    }

    // MARK: helpers

    private static func bestRawSpeakerID(for w: WhisperSegment, in diary: [DiarizedSegment]) -> Int? {
        var best: (id: Int, overlap: Double) = (0, 0)
        for d in diary {
            let overlap = max(0, min(w.end, d.end) - max(w.start, d.start))
            if overlap > best.overlap { best = (d.speakerId, overlap) }
        }
        return best.overlap > 0 ? best.id : nil
    }

    private static func nearestRawSpeakerID(to w: WhisperSegment, in diary: [DiarizedSegment]) -> Int? {
        let mid = (w.start + w.end) / 2
        return diary.min(by: { a, b in
            distance(from: a.start...a.end, to: mid)
                < distance(from: b.start...b.end, to: mid)
        })?.speakerId
    }

    private static func distance(from range: ClosedRange<Double>, to point: Double) -> Double {
        if range.contains(point) { return 0 }
        return min(abs(point - range.lowerBound), abs(point - range.upperBound))
    }
}
