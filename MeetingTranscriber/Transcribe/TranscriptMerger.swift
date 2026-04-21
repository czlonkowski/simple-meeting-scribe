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
