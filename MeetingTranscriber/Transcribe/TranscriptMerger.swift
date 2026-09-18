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

    /// Level difference (dB) past which a segment's source overrides the
    /// cloud speaker: only unambiguous cases, e.g. a muted mic or a silent
    /// system stem. Talking over each other stays below it (checked on three
    /// meetings: 10 dB flips correct double-talk labels, 20 dB only real errors).
    static let decisiveStemMarginDB: Float = 20

    /// Map a single diarized transcription (the combined-mix cloud path) to
    /// app speakers. `diarization` is parallel to `segments` (one entry per
    /// segment), and so is `stemLevels` when both stems exist.
    ///
    /// The system stem carries only remote audio, so stem levels decide which
    /// cloud speaker is "You": the one whose speech is mostly louder on the mic.
    /// The cloud's speaker identity is kept, except where one stem is louder by
    /// `decisiveStemMarginDB` — that corrects a cloud speaker merging the user
    /// with remote audio, or remote audio labelled as the user. Without stem
    /// levels (imported files) speakers are labelled "Speaker 1..N".
    static func mapDiarizedSingle(segments: [WhisperSegment],
                                  diarization: [DiarizedSegment],
                                  stemLevels: [StemLevels]?)
        -> (segments: [TranscriptSegment], speakers: [SpeakerLabel]) {

        guard !segments.isEmpty else { return ([], []) }
        guard segments.count == diarization.count else {
            // No per-segment speaker info — single anonymous speaker.
            let segs = segments.map {
                TranscriptSegment(start: $0.start, end: $0.end, speakerId: 1, text: $0.text)
            }
            return (segs, [SpeakerLabel(id: 1, name: "Speaker 1")])
        }

        guard let levels = stemLevels, levels.count == segments.count else {
            var idMap: [Int: Int] = [:]
            var speakers: [SpeakerLabel] = []
            let segs = zip(segments, diarization).map { seg, d in
                if idMap[d.speakerId] == nil {
                    idMap[d.speakerId] = idMap.count + 1
                    speakers.append(SpeakerLabel(id: idMap.count, name: "Speaker \(idMap.count)"))
                }
                return TranscriptSegment(start: seg.start, end: seg.end,
                                         speakerId: idMap[d.speakerId] ?? -1, text: seg.text)
            }
            return (segs, speakers)
        }

        // "You" = the cloud speaker whose speech is mostly louder on the mic.
        var localTime: [Int: Double] = [:]
        var totalTime: [Int: Double] = [:]
        for (seg, (d, level)) in zip(segments, zip(diarization, levels)) {
            let duration = seg.end - seg.start
            totalTime[d.speakerId, default: 0] += duration
            if level.mic > level.system { localTime[d.speakerId, default: 0] += duration }
        }
        let youRawID: Int? = totalTime
            .map { (id: $0.key, fraction: (localTime[$0.key] ?? 0) / max($0.value, 0.001), time: $0.value) }
            .filter { $0.fraction >= 0.5 }
            .max { ($0.fraction, $0.time) < ($1.fraction, $1.time) }?.id

        // Remote speakers keyed by cloud id; the user's cloud id only shows up
        // here for audio that was decisively remote (key `nil`).
        var remoteKeys: [Int?] = []
        let isLocal: [Bool] = zip(diarization, levels).map { d, level in
            if level.mic - level.system >= decisiveStemMarginDB { return true }
            if level.system - level.mic >= decisiveStemMarginDB { return false }
            return d.speakerId == youRawID
        }
        for (d, local) in zip(diarization, isLocal) where !local {
            let key: Int? = d.speakerId == youRawID ? nil : d.speakerId
            if !remoteKeys.contains(key) { remoteKeys.append(key) }
        }

        var speakers: [SpeakerLabel] = []
        if isLocal.contains(true) { speakers.append(SpeakerLabel(id: 1, name: "You")) }
        for (offset, _) in remoteKeys.enumerated() {
            speakers.append(SpeakerLabel(id: offset + 2,
                                         name: remoteKeys.count == 1 ? "Remote" : "Remote \(offset + 1)"))
        }

        let segs = zip(segments, zip(diarization, isLocal)).map { seg, pair in
            let (d, local) = pair
            let key: Int? = d.speakerId == youRawID ? nil : d.speakerId
            let id = local ? 1 : (remoteKeys.firstIndex(of: key).map { $0 + 2 } ?? -1)
            return TranscriptSegment(start: seg.start, end: seg.end, speakerId: id, text: seg.text)
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
