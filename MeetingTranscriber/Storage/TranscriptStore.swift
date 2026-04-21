import Foundation

final class TranscriptStore {
    static let shared = TranscriptStore()

    let rootURL: URL
    let recordingsDir: URL

    /// Resolve the voice-stem audio file for a transcript, if it exists on disk.
    /// Returns nil if the transcript has no recorded audio (imported text-only
    /// or the file was manually deleted).
    func audioURL(for doc: TranscriptDocument) -> URL? {
        guard let name = doc.audioFileName else { return nil }
        let url = recordingsDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Remove every file belonging to a transcript — markdown, JSON, and the
    /// paired `.voice.wav` / `.system.wav` recordings. Missing files are
    /// silently skipped so the call is idempotent.
    func delete(_ doc: TranscriptDocument) {
        let fm = FileManager.default
        let md   = rootURL.appendingPathComponent("\(doc.id).md")
        let json = rootURL.appendingPathComponent("\(doc.id).json")
        try? fm.removeItem(at: md)
        try? fm.removeItem(at: json)

        if let voice = doc.audioFileName {
            let voiceURL = recordingsDir.appendingPathComponent(voice)
            try? fm.removeItem(at: voiceURL)
            // Paired system stem shares the base filename with a `.system.wav` suffix.
            let base = (voice as NSString).deletingPathExtension      // "2026-04-21_141234.voice"
            let stem = (base as NSString).deletingPathExtension       // "2026-04-21_141234"
            let systemURL = recordingsDir.appendingPathComponent("\(stem).system.wav")
            try? fm.removeItem(at: systemURL)
        }
    }

    private init() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        self.rootURL = docs.appendingPathComponent("MeetingTranscripts", isDirectory: true)
        self.recordingsDir = rootURL.appendingPathComponent("recordings", isDirectory: true)
        try? fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    }

    func save(_ doc: TranscriptDocument, audioSource: URL?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(doc)
        let jsonURL = rootURL.appendingPathComponent("\(doc.id).json")
        try jsonData.write(to: jsonURL)

        let md = TranscriptFormatter.renderMarkdown(doc)
        let mdURL = rootURL.appendingPathComponent("\(doc.id).md")
        try md.data(using: .utf8)?.write(to: mdURL)

        // If an audio source was provided and is outside recordings/, copy it in.
        if let audioSource = audioSource {
            if audioSource.deletingLastPathComponent().standardizedFileURL != recordingsDir.standardizedFileURL {
                let dest = recordingsDir.appendingPathComponent(doc.audioFileName ?? audioSource.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: audioSource, to: dest)
                }
            }
        }
    }

    func loadAll() throws -> [TranscriptDocument] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootURL.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: rootURL,
                                               includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var docs: [TranscriptDocument] = []
        for f in files {
            do {
                let data = try Data(contentsOf: f)
                let doc = try decoder.decode(TranscriptDocument.self, from: data)
                docs.append(doc)
            } catch {
                NSLog("Skipping malformed transcript \(f.lastPathComponent): \(error)")
            }
        }
        return docs
    }

    func delete(id: String) throws {
        let fm = FileManager.default
        let jsonURL = rootURL.appendingPathComponent("\(id).json")
        let mdURL = rootURL.appendingPathComponent("\(id).md")
        try? fm.removeItem(at: jsonURL)
        try? fm.removeItem(at: mdURL)
    }
}
