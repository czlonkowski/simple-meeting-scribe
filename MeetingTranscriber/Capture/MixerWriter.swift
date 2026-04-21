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
            NSLog("StemWriter: write failed — \(error)")
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
