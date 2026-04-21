import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Captures system audio from the main display using ScreenCaptureKit.
/// Delivers resampled 16 kHz mono f32 samples to the consumer.
///
/// Config mirrors the one used by `silverstein/minutes` (known-working on
/// macOS 14+/15): `SCRecordingOutput`-friendly video stub + `.audio` output
/// only — no `.screen` or `.microphone` output types.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias SampleConsumer = ([Float]) async -> Void

    var onSamples: SampleConsumer?

    private var stream: SCStream?
    private let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private let outputQueue = DispatchQueue(label: "sc.audio.out", qos: .userInteractive)
    private var didLogFirstCallback = false
    private var sampleCount = 0

    func start(preferredBundleID _: String) async throws {
        NSLog("SystemAudio: requesting SCShareableContent")
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        NSLog("SystemAudio: \(content.applications.count) apps, \(content.displays.count) displays")

        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No capturable display."])
        }

        // Match minutes' filter exactly: empty excludes + empty exceptingWindows.
        let filter = SCContentFilter(display: display,
                                     excludingApplications: [],
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        NSLog("SystemAudio: stream started")
        self.stream = stream
        self.didLogFirstCallback = false
        self.sampleCount = 0
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            NSLog("SystemAudio: stopCapture failed: \(error)")
        }
        self.stream = nil
        self.converter = nil
        self.lastInputFormat = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if !didLogFirstCallback {
            didLogFirstCallback = true
            NSLog("SystemAudio: first stream callback (type=\(type.rawValue))")
        }
        guard type == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let asbd = asbdPtr.pointee

        let inputFormat = AVAudioFormat(streamDescription: asbdPtr)
            ?? AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                             channels: AVAudioChannelCount(asbd.mChannelsPerFrame))
        guard let inputFormat else { return }

        if converter == nil || lastInputFormat != inputFormat {
            let conv = AVAudioConverter(from: inputFormat, to: targetFormat)
            // High-quality anti-aliased resampling at the 48k→16k boundary.
            // Default quality trades noticeable aliasing for speed; Whisper WER
            // is very sensitive to that aliasing.
            conv?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            conv?.sampleRateConverterQuality = .max
            converter = conv
            lastInputFormat = inputFormat
            NSLog("SystemAudio: converter input format = \(inputFormat) (mastering/.max)")
        }
        guard let converter else { return }

        guard let inputPCM = Self.makePCMBuffer(from: sampleBuffer, format: inputFormat) else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inputPCM.frameLength) * ratio + 32)
        guard let outputPCM = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: outputPCM, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inputPCM
        }
        guard status != .error, let ch = outputPCM.floatChannelData?[0] else { return }
        let count = Int(outputPCM.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: count))
        sampleCount += count
        if sampleCount == count || sampleCount % (16_000 * 5) < count {
            NSLog("SystemAudio: received batch (\(count) samples, \(sampleCount) total)")
        }
        Task { [weak self] in await self?.onSamples?(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SystemAudio: stopped with error \(error)")
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer,
                                      format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(sampleCount)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(sampleCount)

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let data = dataPointer else { return nil }

        let channelCount = Int(format.channelCount)
        let asbd = format.streamDescription.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = isFloat ? 4 : 2

        if format.isInterleaved {
            // Copy interleaved bytes straight into the PCM buffer.
            if let dst = pcm.audioBufferList.pointee.mBuffers.mData {
                memcpy(dst, data, totalLength)
            }
        } else if isNonInterleaved {
            // Non-interleaved: CM block is [ch0 frames | ch1 frames | ...].
            let planeSize = sampleCount * bytesPerSample
            let channelsData = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            for ch in 0..<channelCount where ch < channelsData.count {
                let srcOff = ch * planeSize
                if srcOff + planeSize <= totalLength,
                   let dst = channelsData[ch].mData {
                    memcpy(dst, data.advanced(by: srcOff), planeSize)
                }
            }
        } else {
            // Fallback: single-channel contiguous buffer.
            if let dst = pcm.audioBufferList.pointee.mBuffers.mData {
                memcpy(dst, data, min(totalLength, Int(pcm.audioBufferList.pointee.mBuffers.mDataByteSize)))
            }
        }
        return pcm
    }
}
