import Foundation
import AVFoundation

/// Mixes the two recorded stems into a single mono WAV for cloud
/// transcription, and measures each stem's level per transcript segment so
/// the cloud engine's anonymous diarization speakers can be mapped back to
/// "You" and remote participants. Local engines keep using the separate stems.
enum AudioMixdown {

    /// Sample-wise sum of both stems (timeline-aligned by StemWriter; the
    /// shorter one is padded with silence) written to a temporary 16 kHz
    /// mono 16-bit WAV. Caller removes the file when done.
    static func mixToTempWav(voice voiceURL: URL, system systemURL: URL) throws -> URL {
        let voice = try loadSamples(from: voiceURL)
        let system = try loadSamples(from: systemURL)

        var mixed = [Float](repeating: 0, count: max(voice.count, system.count))
        for i in 0..<voice.count { mixed[i] = voice[i] }
        for i in 0..<system.count { mixed[i] += system[i] }
        // Hard clamp is fine here: both stems rarely peak simultaneously and
        // transcription is insensitive to mild clipping.
        for i in 0..<mixed.count { mixed[i] = min(1.0, max(-1.0, mixed[i])) }

        return try writeTempWav(mixed[...], prefix: "cloud_mix")
    }

    /// Writes samples to a temporary 16 kHz mono 16-bit WAV named
    /// `<prefix>_<uuid>.wav`. Caller removes the file when done.
    static func writeTempWav(_ samples: ArraySlice<Float>, prefix: String) throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: outURL,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "AudioMixdown", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"])
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buf.floatChannelData?[0], !samples.isEmpty {
            samples.withUnsafeBufferPointer { src in
                ch.update(from: src.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buf)
        return outURL
    }

    /// Loudness of each stem over each segment, for telling local (mic) from
    /// remote (system) speech in a transcript of the mix. Loads both stems.
    static func stemLevels(voice voiceURL: URL, system systemURL: URL,
                           segments: [WhisperSegment]) throws -> [StemLevels] {
        stemLevels(voice: try loadSamples(from: voiceURL),
                   system: try loadSamples(from: systemURL),
                   sampleRate: 16_000,
                   segments: segments)
    }

    /// RMS level in dBFS of each stem over each segment's time range, floored
    /// at -120 dB for digital silence. Ranges past a stem's end read as silence.
    static func stemLevels(voice: [Float], system: [Float], sampleRate: Double,
                           segments: [WhisperSegment]) -> [StemLevels] {
        func level(_ samples: [Float], _ start: Double, _ end: Double) -> Float {
            let lower = max(0, min(samples.count, Int(start * sampleRate)))
            let upper = max(lower, min(samples.count, Int(end * sampleRate)))
            guard upper > lower else { return -120 }
            var energy: Float = 0
            for i in lower..<upper { energy += samples[i] * samples[i] }
            let rms = (energy / Float(upper - lower)).squareRoot()
            return max(-120, 20 * log10(rms))
        }
        return segments.map {
            StemLevels(mic: level(voice, $0.start, $0.end),
                       system: level(system, $0.start, $0.end))
        }
    }

    /// Loads a 16 kHz mono WAV (our own stem format) as float samples.
    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: capacity) else { return [] }
        try file.read(into: buf)
        let frames = Int(buf.frameLength)
        guard frames > 0, let channels = buf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channels[0], count: frames))
    }
}

/// Per-segment loudness (dBFS) of the mic and system stems. The system stem
/// carries only remote audio, so whichever is louder says where speech came from.
struct StemLevels: Hashable {
    let mic: Float
    let system: Float
}
