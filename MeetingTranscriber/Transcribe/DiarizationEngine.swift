import Foundation
import AVFoundation
import FluidAudio

/// Wraps FluidAudio's offline pyannote-based diarizer.
actor DiarizationEngine {
    private var manager: DiarizerManager?
    private var models: DiarizerModels?

    func diarize(wavURL: URL,
                 progress: @escaping (Double, String) -> Void) async throws -> [DiarizedSegment] {
        progress(0.05, "Loading diarization models")
        if manager == nil {
            let models = try await DiarizerModels.downloadIfNeeded()
            let mgr = DiarizerManager()
            mgr.initialize(models: models)
            self.manager = mgr
            self.models = models
        }
        progress(0.3, "Analyzing speakers")
        let samples = try Self.load16kMonoSamples(from: wavURL)
        guard let manager else { return [] }
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)
        return result.segments.map {
            DiarizedSegment(start: Double($0.startTimeSeconds),
                            end: Double($0.endTimeSeconds),
                            speakerId: Self.intSpeakerID(from: $0.speakerId))
        }
    }

    private static func intSpeakerID(from raw: String) -> Int {
        // FluidAudio returns strings like "Speaker 1" or "speaker_0" depending on version.
        let digits = raw.filter { $0.isNumber }
        return Int(digits) ?? abs(raw.hashValue % 32)
    }

    private static func load16kMonoSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: capacity) else { return [] }
        try file.read(into: buf)

        let frames = Int(buf.frameLength)
        guard frames > 0 else { return [] }
        let channelCount = Int(buf.format.channelCount)

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

        let abl = buf.audioBufferList.pointee
        guard let data = abl.mBuffers.mData else { return [] }
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

struct DiarizedSegment: Hashable {
    let start: Double
    let end: Double
    let speakerId: Int
}
