import Foundation
import AVFoundation
import OSLog
import WhisperKit

/// Thin wrapper around WhisperKit.
actor WhisperEngine {
    private var pipelines: [WhisperModel: WhisperKit] = [:]

    func transcribe(url: URL,
                    language: TranscriptionLanguage,
                    model: WhisperModel,
                    initialPrompt: String?,
                    progress: @escaping (Double, String) -> Void) async throws -> [WhisperSegment] {
        progress(0.05, "Loading \(model.shortName)")
        let pipeline = try await pipeline(for: model)
        progress(0.25, "Transcribing (\(language.displayName))…")

        // Load audio ourselves as 16 kHz mono fp32, then pass to WhisperKit's
        // audioArray overload. Bypasses WhisperKit's internal AVAudioFile path
        // which can silently yield zero samples on some WAV variants.
        let samples = try Self.load16kMonoSamples(from: url)
        Log.whisper.notice("loaded \(samples.count, privacy: .public) samples (\(Double(samples.count) / 16_000, privacy: .public)s)")
        guard !samples.isEmpty else {
            Log.whisper.error("audio file produced no samples — aborting")
            return []
        }

        // Whisper "prime" via `DecodingOptions.promptTokens` is disabled —
        // feeding tokenized text produced an empty decode (Whisper returned
        // segments with 0-char text regardless of filtering). Revisit once
        // we have a verified path to inject a conditioning prompt that
        // doesn't clobber the prefill. Dictionary replacements still work as
        // a post-processing pass.
        let promptTokens: [Int]? = nil
        if let text = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            Log.whisper.notice("prime present but currently ignored (priming disabled): \(text, privacy: .public)")
        }

        let decodeOptions = DecodingOptions(
            verbose: true,
            task: .transcribe,
            language: language.rawValue,
            temperature: 0.0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            promptTokens: promptTokens
        )

        let results = try await pipeline.transcribe(audioArray: samples,
                                                    decodeOptions: decodeOptions)
        progress(0.85, "Aligning segments…")
        Log.whisper.notice("got \(results.count, privacy: .public) result chunks")

        var out: [WhisperSegment] = []
        for (i, r) in results.enumerated() {
            Log.whisper.notice("chunk \(i, privacy: .public) — text=\(r.text.count, privacy: .public) chars, segments=\(r.segments.count, privacy: .public), language=\(r.language, privacy: .public)")
            for seg in r.segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                out.append(WhisperSegment(start: Double(seg.start),
                                          end: Double(seg.end),
                                          text: text))
            }
        }

        // Fallback: if segments are empty but the top-level text isn't.
        if out.isEmpty {
            let joined = results.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                Log.whisper.notice("no segments; using joined text as single segment")
                let duration = Double(samples.count) / 16_000
                out.append(WhisperSegment(start: 0, end: duration, text: joined))
            } else {
                Log.whisper.error("empty output")
            }
        }

        return out
    }

    private func pipeline(for model: WhisperModel) async throws -> WhisperKit {
        if let p = pipelines[model] { return p }
        NSLog("Whisper: loading pipeline \"%@\"", model.rawValue)
        let config = WhisperKitConfig(
            model: model.rawValue,
            modelRepo: "argmaxinc/whisperkit-coreml",
            verbose: true,
            prewarm: true,
            load: true,
            download: true
        )
        let pipe = try await WhisperKit(config)
        pipelines[model] = pipe
        NSLog("Whisper: pipeline ready")
        return pipe
    }

    private static func load16kMonoSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let processingFormat = file.processingFormat
        NSLog("Whisper-Load: length=%lld processingFormat=%@",
              file.length, processingFormat)
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0 else {
            NSLog("Whisper-Load: capacity is zero")
            return []
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                         frameCapacity: capacity) else {
            NSLog("Whisper-Load: buffer alloc failed")
            return []
        }
        do {
            try file.read(into: buf)
        } catch {
            NSLog("Whisper-Load: read failed: %@", String(describing: error))
            throw error
        }
        NSLog("Whisper-Load: read frames=%d channels=%d interleaved=%@",
              buf.frameLength, buf.format.channelCount,
              buf.format.isInterleaved ? "true" : "false")

        let frames = Int(buf.frameLength)
        guard frames > 0 else { return [] }
        let channelCount = Int(buf.format.channelCount)

        // Pull mono samples from whichever layout the buffer actually uses.
        if let channels = buf.floatChannelData {
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: channels[0], count: frames))
            }
            var mono = [Float](repeating: 0, count: frames)
            for c in 0..<channelCount {
                let ch = channels[c]
                for i in 0..<frames { mono[i] += ch[i] }
            }
            let scale = 1.0 / Float(channelCount)
            for i in 0..<frames { mono[i] *= scale }
            return mono
        }

        // Fallback for interleaved mono (floatChannelData returns nil on some
        // interleaved variants). Read directly from audioBufferList.
        let abl = buf.audioBufferList.pointee
        guard abl.mBuffers.mNumberChannels > 0,
              let data = abl.mBuffers.mData else {
            NSLog("Whisper-Load: no floatChannelData and no audioBufferList data")
            return []
        }
        let bytes = Int(abl.mBuffers.mDataByteSize)
        let floatCount = bytes / MemoryLayout<Float>.size
        let src = data.bindMemory(to: Float.self, capacity: floatCount)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: src, count: min(floatCount, frames)))
        }
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channelCount {
                sum += src[i * channelCount + c]
            }
            mono[i] = sum / Float(channelCount)
        }
        return mono
    }
}

struct WhisperSegment: Hashable {
    let start: Double
    let end: Double
    let text: String
}
