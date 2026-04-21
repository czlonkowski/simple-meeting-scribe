import Foundation
import OSLog

/// Drives the full transcribe + diarize + merge pass across the voice stem
/// (mic) and the optional system-audio stem. Each stem is transcribed
/// independently so overlapping voices don't fight for Whisper's attention.
final class TranscriptionPipeline {
    private let whisper = WhisperEngine()
    private let diarizer = DiarizationEngine()

    func run(voiceURL: URL,
             systemURL: URL?,
             duration: TimeInterval,
             language: TranscriptionLanguage,
             model: WhisperModel,
             meeting: DetectedMeeting?,
             sourceKind: TranscriptDocument.SourceKind,
             importedFileName: String?,
             initialPrompt: String?,
             wordReplacements: [WordReplacement],
             progress: @escaping (Double, String) -> Void) async throws -> TranscriptDocument {

        Log.pipeline.notice("starting voice=\(voiceURL.lastPathComponent, privacy: .public) system=\(systemURL?.lastPathComponent ?? "-", privacy: .public) duration=\(Int(duration), privacy: .public)s")

        // ----- Voice stem (mic) -----
        progress(0.05, "Transcribing your voice")
        let voiceSegs: [WhisperSegment]
        do {
            voiceSegs = try await whisper.transcribe(
                url: voiceURL,
                language: language,
                model: model,
                initialPrompt: initialPrompt,
                progress: { p, s in progress(0.05 + p * 0.30, s) }
            )
            Log.pipeline.notice("voice produced \(voiceSegs.count, privacy: .public) segments")
        } catch {
            Log.pipeline.error("voice transcription failed — \(String(describing: error), privacy: .public)")
            throw error
        }

        // ----- System stem (remote speakers) -----
        var systemSegs: [WhisperSegment] = []
        var systemDiar: [DiarizedSegment] = []
        if let systemURL = systemURL {
            progress(0.40, "Transcribing system audio")
            do {
                systemSegs = try await whisper.transcribe(
                    url: systemURL,
                    language: language,
                    model: model,
                    initialPrompt: initialPrompt,
                    progress: { p, s in progress(0.40 + p * 0.30, s) }
                )
                Log.pipeline.notice("system produced \(systemSegs.count, privacy: .public) segments")
            } catch {
                Log.pipeline.error("system transcription failed — \(String(describing: error), privacy: .public) (continuing)")
            }

            if !systemSegs.isEmpty {
                do {
                    systemDiar = try await diarizer.diarize(
                        wavURL: systemURL,
                        progress: { p, s in progress(0.70 + p * 0.15, s) }
                    )
                    Log.pipeline.notice("system diarizer produced \(systemDiar.count, privacy: .public) segments")
                } catch {
                    Log.pipeline.error("system diarizer failed — \(String(describing: error), privacy: .public)")
                }
            }
        }

        progress(0.92, "Merging")
        let cutoff = duration + 0.5
        let trimmedVoice  = voiceSegs.filter  { $0.start < cutoff }
        let trimmedSystem = systemSegs.filter { $0.start < cutoff }
        if trimmedVoice.count != voiceSegs.count || trimmedSystem.count != systemSegs.count {
            Log.pipeline.notice("trimmed \((voiceSegs.count + systemSegs.count) - (trimmedVoice.count + trimmedSystem.count), privacy: .public) hallucination(s) past end-of-audio")
        }

        var merged = TranscriptMerger.mergeStems(
            voice: trimmedVoice,
            system: trimmedSystem,
            systemDiarization: systemDiar
        )

        // Post-processing: apply user word replacements to every segment.
        if !wordReplacements.isEmpty {
            merged.segments = merged.segments.map { seg in
                TranscriptSegment(
                    id: seg.id,
                    start: seg.start,
                    end: seg.end,
                    speakerId: seg.speakerId,
                    text: WordReplacementService.apply(wordReplacements, to: seg.text)
                )
            }
        }

        progress(0.98, "Saving")
        let id = Self.makeID()
        let title = meeting?.title ?? (importedFileName ?? Self.fallbackTitle(from: voiceURL))

        return TranscriptDocument(
            id: id,
            title: title,
            date: Date(),
            duration: duration,
            language: language,
            modelShortName: model.shortName,
            sourceURL: meeting?.url ?? importedFileName,
            sourceKind: sourceKind,
            speakers: merged.speakers,
            segments: merged.segments,
            audioFileName: voiceURL.lastPathComponent
        )
    }

    private static func makeID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }

    private static func fallbackTitle(from url: URL) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Recording — \(f.string(from: Date()))"
    }
}
