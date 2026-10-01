import AVFoundation
import Accelerate
import CoreAudio
import Foundation

/// Captures the audio output of specific processes with a Core Audio process
/// tap (macOS 14.2+) and delivers 16 kHz mono f32 samples, like
/// `SystemAudioCapture`.
///
/// Exists for iPhone and FaceTime calls: their remote audio is played by the
/// `avconferenced` daemon, which owns no windows, and the display-scoped
/// ScreenCaptureKit stream records it as pure digital silence (verified on a
/// live call 2026-10-01). A process tap reads the daemon's output directly.
/// Needs the "System Audio Recording Only" permission
/// (`NSAudioCaptureUsageDescription`); without it the tap delivers zeros.
final class ProcessTapCapture: @unchecked Sendable {
    typealias SampleConsumer = ([Float]) async -> Void

    var onSamples: SampleConsumer?
    var onLevel: ((Float) -> Void)?

    private let executableNames: [String]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "process.tap", qos: .userInteractive)
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    init(executableNames: [String]) {
        self.executableNames = executableNames
    }

    func start() throws {
        let processes = CoreAudioClients.processObjects(executableNames: executableNames)
        guard !processes.isEmpty else {
            throw Self.error("No audio process named \(executableNames.joined(separator: ", ")).")
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        var format = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read tap format")
        guard let inputFormat = AVAudioFormat(streamDescription: &format) else {
            throw Self.error("Unsupported tap format.")
        }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                 channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: mono, to: targetFormat)
        converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter?.sampleRateConverterQuality = .max
        self.converter = converter

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingTranscriber call tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                       "create aggregate device")

        let channels = Int(inputFormat.channelCount)
        let interleaved = inputFormat.isInterleaved
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let mixed = Self.downmix(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                                     channels: channels, interleaved: interleaved)
            guard !mixed.isEmpty else { return }
            self.deliver(mixed, inputFormat: mono)
        }, "create IO proc")
        try Self.check(AudioDeviceStart(aggregateID, ioProcID), "start tap device")
        Log.systemAudio.notice("process tap started on \(self.executableNames.joined(separator: ","), privacy: .public)")
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Runs on `queue`.
    private func deliver(_ mono: [Float], inputFormat: AVAudioFormat) {
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(mono.count))
        else { return }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }

        let capacity = AVAudioFrameCount(Double(mono.count) * targetFormat.sampleRate / inputFormat.sampleRate + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        let status = converter.convert(to: output, error: nil) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(rms) }
        Task { [weak self] in await self?.onSamples?(samples) }
    }

    private static func downmix(_ buffers: UnsafeMutableAudioBufferListPointer,
                                channels: Int, interleaved: Bool) -> [Float] {
        if interleaved {
            guard let buffer = buffers.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self),
                  channels > 0 else { return [] }
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            return (0..<frames).map { frame in
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                return sum / Float(channels)
            }
        }
        var mixed: [Float] = []
        let planes = buffers.compactMap { buffer -> UnsafeBufferPointer<Float>? in
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            return UnsafeBufferPointer(start: data, count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        }
        guard let frames = planes.map(\.count).min(), frames > 0 else { return [] }
        mixed = [Float](repeating: 0, count: frames)
        for plane in planes {
            vDSP_vadd(mixed, 1, plane.baseAddress!, 1, &mixed, 1, vDSP_Length(frames))
        }
        var scale = 1 / Float(planes.count)
        vDSP_vsmul(mixed, 1, &scale, &mixed, 1, vDSP_Length(frames))
        return mixed
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw error("Process tap: \(step) failed (\(status)).") }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ProcessTapCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
