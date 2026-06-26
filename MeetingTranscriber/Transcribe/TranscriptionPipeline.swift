import Foundation
import OSLog

/// Drives the full transcribe + diarize + merge pass across the voice stem
/// (mic) and the optional system-audio stem. Each stem is transcribed
/// independently so overlapping voices don't fight for Whisper's attention.
final class TranscriptionPipeline {
    private let whisper = WhisperEngine()
    private let diarizer = DiarizationEngine()
    private let scribe = ScribeEngine()

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

        var merged: (segments: [TranscriptSegment], speakers: [SpeakerLabel])
        let cutoff = duration + 0.5

        if model.isCloud {
            // ----- Cloud path (ElevenLabs Scribe v2) -----
            // Unlike the local engines, both stems go up as ONE combined mix:
            // Scribe's diarization separates all speakers in a single call,
            // halving upload size and billed audio-minutes. The mic stem is
            // still used locally to figure out which diarized speaker is
            // "You". initialPrompt has no Scribe equivalent and is ignored;
            // word replacements still apply as post-processing below.
            guard let apiKey = ScribeStore.loadAPIKey() else {
                throw ScribeEngine.ScribeError.missingAPIKey
            }

            let uploadURL: URL
            var mixCleanupURL: URL? = nil
            var voiceActivity: [(start: Double, end: Double)] = []
            let diarize: Bool
            if let systemURL = systemURL {
                progress(0.03, "Mixing stems")
                uploadURL = try AudioMixdown.mixToTempWav(voice: voiceURL, system: systemURL)
                mixCleanupURL = uploadURL
                voiceActivity = (try? AudioMixdown.voiceActivityIntervals(in: voiceURL)) ?? []
                diarize = true
            } else {
                uploadURL = voiceURL
                // Imported files may contain a whole meeting's speakers;
                // a live mic-only recording is just "You".
                diarize = sourceKind == .imported
            }
            defer {
                if let url = mixCleanupURL { try? FileManager.default.removeItem(at: url) }
            }

            let result = try await scribe.transcribe(
                url: uploadURL,
                language: language,
                diarize: diarize,
                apiKey: apiKey,
                progress: { p, s in progress(0.05 + p * 0.85, s) }
            )
            Log.pipeline.notice("scribe produced \(result.segments.count, privacy: .public) segments (diarize=\(diarize, privacy: .public))")

            progress(0.92, "Merging")
            if diarize {
                var segs: [WhisperSegment] = []
                var diar: [DiarizedSegment] = []
                for (s, d) in zip(result.segments, result.diarization) where s.start < cutoff {
                    segs.append(s)
                    diar.append(d)
                }
                merged = TranscriptMerger.mapDiarizedSingle(segments: segs,
                                                            diarization: diar,
                                                            voiceActivity: voiceActivity)
            } else {
                let segs = result.segments.filter { $0.start < cutoff }
                merged = TranscriptMerger.mergeStems(voice: segs,
                                                     system: [],
                                                     systemDiarization: [])
            }
        } else {
            var voiceSegs: [WhisperSegment] = []
            var systemSegs: [WhisperSegment] = []
            var systemDiar: [DiarizedSegment] = []
            // ----- Voice stem (mic) -----
            progress(0.05, "Transcribing your voice")
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
            let trimmedVoice  = voiceSegs.filter  { $0.start < cutoff }
            let trimmedSystem = systemSegs.filter { $0.start < cutoff }
            if trimmedVoice.count != voiceSegs.count || trimmedSystem.count != systemSegs.count {
                Log.pipeline.notice("trimmed \((voiceSegs.count + systemSegs.count) - (trimmedVoice.count + trimmedSystem.count), privacy: .public) hallucination(s) past end-of-audio")
            }

            merged = TranscriptMerger.mergeStems(
                voice: trimmedVoice,
                system: trimmedSystem,
                systemDiarization: systemDiar
            )
        }

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
