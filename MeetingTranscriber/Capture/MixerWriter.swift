import Foundation
import AVFoundation

/// Writes the two sources (mic and system audio) to *separate* 16 kHz mono
/// WAV stems. No mixing is performed — transcribing the stems independently
/// gives much cleaner Whisper output when both sides speak.
///
/// Produces:
///   `<base>.voice.wav`   — microphone stream (always written)
///   `<base>.system.wav`  — system-audio stream (only when samples arrive)
actor StemWriter {
    let voiceURL: URL
    let systemURL: URL

    private var voiceFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private let processingFormat: AVAudioFormat
    private var didWriteSystem = false
    private var muted = false

    init(baseURL: URL) throws {
        let base = baseURL.deletingPathExtension().path
        self.voiceURL = URL(fileURLWithPath: base + ".voice.wav")
        self.systemURL = URL(fileURLWithPath: base + ".system.wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let voice = try AVAudioFile(
            forWriting: voiceURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.voiceFile = voice
        self.processingFormat = voice.processingFormat
    }

    func setMicMuted(_ muted: Bool) {
        self.muted = muted
    }

    func appendMic(_ samples: [Float]) async {
        guard let file = voiceFile else { return }
        // When muted, still write silence so the timeline stays aligned.
        let payload = muted ? [Float](repeating: 0, count: samples.count) : samples
        write(payload, to: file)
    }

    func appendSystem(_ samples: [Float]) async {
        if systemFile == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            systemFile = try? AVAudioFile(
                forWriting: systemURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }
        guard let file = systemFile else { return }
        write(samples, to: file)
        didWriteSystem = true
    }

    /// Pad the system stem with `seconds` of silence to cover a stretch where
    /// the capture produced nothing at all — currently only a stream rebuild.
    ///
    /// This is not cosmetic. Both stems are append-only and are merged by
    /// timestamp downstream, so their sample counts *are* the timeline: a
    /// one-second unpadded gap shifts every later system segment one second
    /// early, for the rest of the recording. Padding keeps the stems in step.
    ///
    /// No-op before any real system audio has been written, so a session that
    /// never captured system audio doesn't get a file made of pure silence.
    func padSystem(seconds: TimeInterval) async {
        guard didWriteSystem, let file = systemFile else { return }
        let frames = Int((seconds * processingFormat.sampleRate).rounded())
        // Sub-20 ms gaps are below the transcript's resolution; padding them
        // adds risk without buying alignment.
        guard frames > 0, seconds >= 0.02 else { return }
        Log.systemAudio.notice("padding system stem with \(seconds, format: .fixed(precision: 2), privacy: .public)s of silence")

        let chunk = Int(processingFormat.sampleRate)   // 1 s at a time
        var remaining = frames
        while remaining > 0 {
            let n = min(chunk, remaining)
            write([Float](repeating: 0, count: n), to: file)
            remaining -= n
        }
    }

    private func write(_ samples: [Float], to file: AVAudioFile) {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buf.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                ch.update(from: src.baseAddress!, count: samples.count)
            }
        }
        do {
            try file.write(from: buf)
        } catch {
            Log.recorder.error("stem write failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Close both files. Releasing the `AVAudioFile` triggers WAV header
    /// finalization; without this the readers see length=0.
    func close() async -> (voice: URL, system: URL?) {
        voiceFile = nil
        systemFile = nil
        return (voiceURL, didWriteSystem ? systemURL : nil)
    }
}
