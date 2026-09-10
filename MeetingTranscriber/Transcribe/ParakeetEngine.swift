import Foundation
import AVFoundation
import OSLog
import FluidAudio

/// Local transcription with NVIDIA Parakeet TDT 0.6B v3 through FluidAudio's
/// Core ML port. Produces the same `WhisperSegment` shape as `WhisperEngine`
/// so the pipeline, merger and diarizer stay unchanged.
///
/// Parakeet detects the language itself (25 European languages, Polish and
/// English included) and has no conditioning-prompt input, so the language
/// setting and the priming text are not forwarded.
actor ParakeetEngine {
    private var manager: AsrManager?

    func transcribe(url: URL,
                    progress: @escaping (Double, String) -> Void) async throws -> [WhisperSegment] {
        progress(0.05, "Loading Parakeet v3")
        let manager = try await loadedManager()
        progress(0.25, "Transcribing (Parakeet)…")

        let result = try await manager.transcribe(url, source: .system)
        Log.parakeet.notice("transcribed \(url.lastPathComponent, privacy: .public) in \(result.processingTime, privacy: .public)s, \(result.tokenTimings?.count ?? 0, privacy: .public) tokens")

        progress(0.85, "Aligning segments…")
        let tokens = (result.tokenTimings ?? []).map {
            ParakeetToken(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        var segments = ParakeetSegmenter.segments(from: tokens)

        // Token timings are optional in FluidAudio's result; fall back to one
        // segment spanning the file rather than dropping the text. (The
        // result's own `duration` field is 0 on the disk-backed path, so
        // measure the file instead.)
        if segments.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                Log.parakeet.notice("no token timings; using whole text as one segment")
                segments = [WhisperSegment(start: 0, end: Self.fileDuration(url), text: text)]
            } else {
                Log.parakeet.error("empty output")
            }
        }
        return segments
    }

    private static func fileDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        Log.parakeet.notice("downloading/loading parakeet-tdt-0.6b-v3 models")
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        Log.parakeet.notice("models ready")
        return manager
    }
}
