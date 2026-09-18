import Foundation
import OSLog

/// Drives the full transcribe + diarize + merge pass across the voice stem
/// (mic) and the optional system-audio stem. Each stem is transcribed
/// independently so overlapping voices don't fight for Whisper's attention.
final class TranscriptionPipeline {
    private let whisper = WhisperEngine()
    private let diarizer = DiarizationEngine()
    private let scribe = ScribeEngine()
    private let parakeet = ParakeetEngine()

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
             phraseHints: [String],
             progress: @escaping (Double, String) -> Void) async throws -> TranscriptDocument {

        Log.pipeline.notice("starting voice=\(voiceURL.lastPathComponent, privacy: .public) system=\(systemURL?.lastPathComponent ?? "-", privacy: .public) duration=\(Int(duration), privacy: .public)s")

        var merged: (segments: [TranscriptSegment], speakers: [SpeakerLabel])
        let cutoff = duration + 0.5
        /// Differs from `model` only when a failed MAI run fell back to Scribe.
        var engineUsed = model

        if model.isCloud {
            // ----- Cloud path (ElevenLabs Scribe v2 / MAI-Transcribe-2) -----
            // Unlike the local engines, both stems go up as ONE combined mix:
            // the cloud diarization separates all speakers in a single call,
            // halving upload size and billed audio-minutes. The mic stem is
            // still used locally to figure out which diarized speaker is
            // "You". initialPrompt has no cloud equivalent and is ignored
            // (MAI gets glossary `phraseHints` instead); word replacements
            // still apply as post-processing below.
            let apiKey: String
            var mai: MAITranscribeEngine?
            if model == .maiTranscribe2 {
                guard let key = AzureSpeechStore.loadAPIKey() else {
                    throw MAITranscribeEngine.MAIError.missingAPIKey
                }
                guard let url = MAITranscribeEngine.transcribeURL(endpoint: AzureSpeechStore.loadEndpoint()) else {
                    throw MAITranscribeEngine.MAIError.missingEndpoint
                }
                apiKey = key
                mai = MAITranscribeEngine(transcribeURL: url)
            } else {
                guard let key = ScribeStore.loadAPIKey() else {
                    throw ScribeEngine.ScribeError.missingAPIKey
                }
                apiKey = key
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

            let cloudProgress: (Double, String) -> Void = { p, s in progress(0.05 + p * 0.85, s) }
            func transcribeWithScribe(apiKey: String) async throws -> (segments: [WhisperSegment], diarization: [DiarizedSegment]) {
                let scribed = try await scribe.transcribe(
                    url: uploadURL,
                    language: language,
                    diarize: diarize,
                    apiKey: apiKey,
                    progress: cloudProgress
                )
                return (scribed.segments, scribed.diarization)
            }
            let result: (segments: [WhisperSegment], diarization: [DiarizedSegment])
            if let mai {
                do {
                    result = try await transcribeWithMAI(mai,
                                                         url: uploadURL,
                                                         duration: duration,
                                                         diarize: diarize,
                                                         phraseHints: phraseHints,
                                                         apiKey: apiKey,
                                                         progress: cloudProgress)
                } catch let error as MAITranscribeEngine.MAIError where error.allowsScribeFallback {
                    // MAI is a preview service; Scribe is the proven engine.
                    // The saved document records Scribe so a fallback is visible.
                    guard let scribeKey = ScribeStore.loadAPIKey() else { throw error }
                    Log.pipeline.error("mai failed — \(String(describing: error), privacy: .public) — falling back to Scribe v2")
                    progress(0.05, "MAI-Transcribe failed — using Scribe v2")
                    result = try await transcribeWithScribe(apiKey: scribeKey)
                    engineUsed = .scribeV2
                }
            } else {
                result = try await transcribeWithScribe(apiKey: apiKey)
            }
            Log.pipeline.notice("\(engineUsed.shortName, privacy: .public) produced \(result.segments.count, privacy: .public) segments (diarize=\(diarize, privacy: .public))")

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
            if model.isParakeet, let text = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Log.pipeline.notice("parakeet has no prompt input; ignoring prime: \(text, privacy: .public)")
            }
            // Local engines share one signature so both stems route the same way.
            func transcribeLocal(_ url: URL,
                                 progress p: @escaping (Double, String) -> Void) async throws -> [WhisperSegment] {
                if model.isParakeet {
                    return try await parakeet.transcribe(url: url, progress: p)
                }
                return try await whisper.transcribe(url: url,
                                                    language: language,
                                                    model: model,
                                                    initialPrompt: initialPrompt,
                                                    progress: p)
            }

            // ----- Voice stem (mic) -----
            progress(0.05, "Transcribing your voice")
            do {
                voiceSegs = try await transcribeLocal(
                    voiceURL,
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
                    systemSegs = try await transcribeLocal(
                        systemURL,
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
            modelShortName: engineUsed.shortName,
            sourceURL: meeting?.url ?? importedFileName,
            sourceKind: sourceKind,
            speakers: merged.speakers,
            segments: merged.segments,
            audioFileName: voiceURL.lastPathComponent
        )
    }

    /// MAI-Transcribe-2 with native diarization when the recording fits one
    /// request. Longer recordings, or a failed diarization request, fall back
    /// to MAI text only (chunked when needed) with speakers from FluidAudio
    /// over the whole mix, so labels stay consistent across chunks.
    private func transcribeWithMAI(_ mai: MAITranscribeEngine,
                                   url: URL,
                                   duration: TimeInterval,
                                   diarize: Bool,
                                   phraseHints: [String],
                                   apiKey: String,
                                   progress: @escaping (Double, String) -> Void)
        async throws -> (segments: [WhisperSegment], diarization: [DiarizedSegment]) {

        func segments(_ spans: [MAISpan]) -> [WhisperSegment] {
            spans.map { WhisperSegment(start: $0.start, end: $0.end, text: $0.text) }
        }

        if duration <= MAITranscribeEngine.maxRequestSeconds {
            do {
                let phrases = try await mai.transcribe(url: url, diarize: diarize,
                                                       phrases: phraseHints, apiKey: apiKey,
                                                       progress: progress)
                let spans = MAISegmenter.spans(from: phrases)
                let diarization = diarize
                    ? spans.map { DiarizedSegment(start: $0.start, end: $0.end, speakerId: $0.speaker ?? 0) }
                    : []
                return (segments(spans), diarization)
            } catch let error as MAITranscribeEngine.MAIError
                        where MAITranscribeEngine.shouldRetryWithoutDiarization(error, diarize: diarize) {
                Log.pipeline.error("mai: diarized request failed — \(String(describing: error), privacy: .public) — retrying without it, speakers from FluidAudio")
            }
        } else {
            Log.pipeline.notice("mai: \(Int(duration), privacy: .public)s exceeds one request — chunked, speakers from FluidAudio")
        }

        let spans = try await mai.transcribeInChunks(url: url,
                                                     phrases: phraseHints, apiKey: apiKey,
                                                     progress: { p, s in progress(p * 0.7, s) })
        guard diarize else { return (segments(spans), []) }
        do {
            let local = try await diarizer.diarize(wavURL: url,
                                                   progress: { p, s in progress(0.7 + p * 0.3, s) })
            return (segments(spans), MAISegmenter.assignSpeakers(spans, diarization: local))
        } catch {
            // Text without speakers beats no transcript; the merger labels it one speaker.
            Log.pipeline.error("mai: local diarization failed — \(String(describing: error), privacy: .public)")
            return (segments(spans), [])
        }
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
