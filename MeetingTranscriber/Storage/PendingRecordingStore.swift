import Foundation

/// Finds live recordings that never became a transcript, and keeps the
/// per-recording sidecar metadata. Disk is the source of truth: a recording is
/// pending when its `.voice.wav` exists and no transcript references it, so a
/// crash at any point leaves it recoverable.
enum PendingRecordingStore {
    /// Live recordings are named `yyyy-MM-dd_HHmmss.voice.wav`.
    private static let voiceSuffix = ".voice.wav"
    private static let baseNamePattern = #"^\d{4}-\d{2}-\d{2}_\d{6}$"#
    /// AVAudioFile pads the header so samples start at 4 KB.
    private static let headerBytes: Int64 = 4096
    /// 16 kHz mono 16-bit PCM, as `StemWriter` writes.
    private static let bytesPerSecond: Double = 32_000
    /// Shorter stems are aborted starts, not meetings worth recovering.
    static let minimumDuration: TimeInterval = 1

    // MARK: – Sidecar

    static func sidecarURL(forVoiceURL voiceURL: URL) -> URL? {
        guard let base = baseName(ofVoiceFile: voiceURL.lastPathComponent) else { return nil }
        return voiceURL.deletingLastPathComponent().appendingPathComponent("\(base).meta.json")
    }

    static func readSidecar(forVoiceURL voiceURL: URL) -> RecordingSidecar? {
        guard let url = sidecarURL(forVoiceURL: voiceURL),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingSidecar.self, from: data)
    }

    static func writeSidecar(_ sidecar: RecordingSidecar, forVoiceURL voiceURL: URL) {
        guard let url = sidecarURL(forVoiceURL: voiceURL) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sidecar) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Read-modify-write; no-op when the recording has no sidecar.
    static func updateSidecar(forVoiceURL voiceURL: URL, _ change: (inout RecordingSidecar) -> Void) {
        guard var sidecar = readSidecar(forVoiceURL: voiceURL) else { return }
        change(&sidecar)
        writeSidecar(sidecar, forVoiceURL: voiceURL)
    }

    static func deleteSidecar(forVoiceURL voiceURL: URL) {
        guard let url = sidecarURL(forVoiceURL: voiceURL) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: – Scan

    /// Every live recording in `recordingsDir` whose voice stem is not in
    /// `referencedVoiceFiles`, newest first. Read-only: headers are not
    /// repaired here. Safe to call off the main actor.
    static func scan(recordingsDir: URL, referencedVoiceFiles: Set<String>) -> [PendingRecording] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: recordingsDir.path) else { return [] }
        let present = Set(names)
        var result: [PendingRecording] = []
        for name in names where name.hasSuffix(voiceSuffix) && !referencedVoiceFiles.contains(name) {
            guard let base = baseName(ofVoiceFile: name),
                  let startedAt = MeetingLookup.startFromAudioFileName(name) else { continue }
            let voiceURL = recordingsDir.appendingPathComponent(name)
            let size = (try? fm.attributesOfItem(atPath: voiceURL.path)[.size] as? Int64) ?? 0
            let duration = Double(max(0, size - headerBytes)) / bytesPerSecond
            guard duration >= minimumDuration else { continue }

            let system = "\(base).system.wav"
            let video = ["\(base).video.mp4", "\(base).video.mov"].first { present.contains($0) }
            result.append(PendingRecording(
                id: base,
                voiceFileName: name,
                systemFileName: present.contains(system) ? system : nil,
                videoFileName: video,
                startedAt: startedAt,
                estimatedDuration: duration,
                sidecar: readSidecar(forVoiceURL: voiceURL)
            ))
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    /// Voice stems the library already owns. Older transcripts may lack
    /// `audioFileName`, so a doc id equal to the stem base counts too.
    static func referencedVoiceFiles(in docs: [TranscriptDocument]) -> Set<String> {
        var names = Set<String>()
        for doc in docs {
            if let audio = doc.audioFileName { names.insert(audio) }
            names.insert("\(doc.id)\(voiceSuffix)")
        }
        return names
    }

    /// Remove every file of a pending recording. Missing files are skipped.
    static func delete(_ pending: PendingRecording, in recordingsDir: URL) {
        let fm = FileManager.default
        let files = [pending.voiceFileName, pending.systemFileName, pending.videoFileName,
                     "\(pending.id).meta.json"].compactMap { $0 }
        for file in files {
            try? fm.removeItem(at: recordingsDir.appendingPathComponent(file))
        }
    }

    static func baseName(ofVoiceFile name: String) -> String? {
        guard name.hasSuffix(voiceSuffix) else { return nil }
        let base = String(name.dropLast(voiceSuffix.count))
        return base.range(of: baseNamePattern, options: .regularExpression) != nil ? base : nil
    }
}
