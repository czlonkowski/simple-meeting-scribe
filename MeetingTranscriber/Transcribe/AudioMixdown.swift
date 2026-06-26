import Foundation
import AVFoundation

/// Mixes the two recorded stems into a single mono WAV for cloud
/// transcription, and derives a voice-activity timeline from the mic stem so
/// the cloud engine's anonymous diarization speakers can be mapped back to
/// "You". Local engines keep using the separate stems.
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

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe_mix_\(UUID().uuidString).wav")
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
                                         frameCapacity: AVAudioFrameCount(mixed.count)) else {
            throw NSError(domain: "AudioMixdown", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"])
        }
        buf.frameLength = AVAudioFrameCount(mixed.count)
        if let ch = buf.floatChannelData?[0] {
            mixed.withUnsafeBufferPointer { src in
                ch.update(from: src.baseAddress!, count: mixed.count)
            }
        }
        try file.write(from: buf)
        return outURL
    }

    /// Intervals (seconds) where the mic stem carries speech, from a simple
    /// adaptive RMS gate over 100 ms frames. Used to decide which diarized
    /// speaker in the combined mix is the user.
    static func voiceActivityIntervals(in url: URL) throws -> [(start: Double, end: Double)] {
        let samples = try loadSamples(from: url)
        let frame = 1600 // 100 ms @ 16 kHz
        guard samples.count >= frame else { return [] }

        var rms: [Float] = []
        rms.reserveCapacity(samples.count / frame)
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            rms.append((sum / Float(frame)).squareRoot())
            i += frame
        }

        // Adaptive threshold: well above the noise floor (median), with an
        // absolute lower bound so a hot noise floor doesn't gate everything in.
        let sorted = rms.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(0.012, median * 3)

        var intervals: [(start: Double, end: Double)] = []
        var activeStart: Double? = nil
        for (idx, value) in rms.enumerated() {
            let t = Double(idx) * 0.1
            if value > threshold {
                if activeStart == nil { activeStart = t }
            } else if let start = activeStart {
                intervals.append((start, t))
                activeStart = nil
            }
        }
        if let start = activeStart {
            intervals.append((start, Double(rms.count) * 0.1))
        }
        return intervals
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
