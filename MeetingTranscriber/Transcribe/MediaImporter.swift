import Foundation
import AVFoundation

enum MediaImporter {

    /// Decode any audio/video file into a 16 kHz mono 16-bit WAV in the temp
    /// directory, reporting progress 0…1.
    static func convertToMono16kWav(source: URL,
                                    progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(domain: "MediaImporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track in file."])
        }
        let duration = try await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(duration)
        let reader = try AVAssetReader(asset: asset)

        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let readerOut = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: outSettings)
        reader.add(readerOut)
        guard reader.startReading() else {
            throw NSError(domain: "MediaImporter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start audio reader."])
        }

        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let name = source.deletingPathExtension().lastPathComponent
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_\(Int(Date().timeIntervalSince1970))_\(name).wav")
        let workingFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000,
                                       channels: 1,
                                       interleaved: false)!
        let file = try AVAudioFile(forWriting: outURL, settings: wavSettings)

        var framesWritten: Int64 = 0
        while let sample = readerOut.copyNextSampleBuffer() {
            guard let pcm = cmSampleBufferToFloatBuffer(sample, format: workingFmt) else { continue }
            try file.write(from: pcm)
            framesWritten += Int64(pcm.frameLength)
            if durationSec > 0 {
                let seconds = Double(framesWritten) / 16_000.0
                progress(min(0.98, seconds / durationSec))
            }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "MediaImporter", code: 3) }
        progress(1.0)
        return outURL
    }

    static func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration)
        return CMTimeGetSeconds(dur)
    }

    private static func cmSampleBufferToFloatBuffer(_ sb: CMSampleBuffer,
                                                    format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)

        var abl = AudioBufferList(mNumberBuffers: 1,
                                  mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil,
            bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &block)
        guard status == noErr, let data = abl.mBuffers.mData,
              let ch = pcm.floatChannelData?[0] else { return nil }
        let count = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let src = data.bindMemory(to: Float.self, capacity: count)
        ch.update(from: src, count: min(count, Int(pcm.frameLength)))
        return pcm
    }
}
