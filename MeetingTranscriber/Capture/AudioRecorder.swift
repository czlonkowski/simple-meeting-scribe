import Foundation
import AVFoundation
import Accelerate
import CoreAudio

/// Captures microphone audio via AVAudioEngine, downmixes + resamples to
/// 16 kHz mono f32, and forwards to a consumer. Survives input device changes
/// mid-session (AirPods ↔ built-in).
final class AudioRecorder {
    typealias SampleConsumer = ([Float]) async -> Void
    typealias LevelConsumer = (Float) -> Void

    private var engine: AVAudioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: 16_000,
                      channels: 1,
                      interleaved: false)!
    }()

    private let queue = DispatchQueue(label: "audio.recorder")
    private(set) var isRunning = false
    private var muted = false

    private var configChangeObserver: NSObjectProtocol?

    var onSamples: SampleConsumer?
    var onLevel: LevelConsumer?
    /// Fires on the main queue after the engine rebuilds in response to a
    /// default-input-device change (AirPods ↔ built-in ↔ USB mic). Consumers
    /// use this to re-read `AudioRecorder.currentInputDeviceName()`.
    var onInputDeviceChange: (() -> Void)?

    func start() throws {
        guard !isRunning else { return }
        try setupEngineAndTap()
        try engine.start()
        isRunning = true

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    func setMuted(_ muted: Bool) {
        queue.sync { self.muted = muted }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func setupEngineAndTap() throws {
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone available."])
        }
        self.converterInputFormat = hwFormat
        self.converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.handleInputBuffer(buffer)
        }
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        // Level metering (pre-mute so user sees their voice level).
        if let ch = buffer.floatChannelData?[0] {
            let n = vDSP_Length(buffer.frameLength)
            var rms: Float = 0
            vDSP_rmsqv(ch, 1, &rms, n)
            DispatchQueue.main.async { [weak self] in self?.onLevel?(rms) }
        }

        // Muted: emit silence (preserves timing).
        if queue.sync(execute: { muted }) {
            let count = Int(buffer.frameLength) * Int(targetFormat.sampleRate) / Int(converterInputFormat?.sampleRate ?? 16_000)
            let silence = [Float](repeating: 0, count: max(1, count))
            Task { await onSamples?(silence) }
            return
        }

        guard let converter = converter else { return }
        let ratio = targetFormat.sampleRate / (converterInputFormat?.sampleRate ?? 16_000)
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let src = out.floatChannelData?[0] else { return }
        let frameCount = Int(out.frameLength)
        if frameCount == 0 { return }
        let samples = Array(UnsafeBufferPointer(start: src, count: frameCount))
        Task { await onSamples?(samples) }
    }

    private func handleConfigurationChange() {
        // Engine's input format likely changed (device swap). Restart cleanly.
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Rebuild engine to pick up the new default input device fully.
        engine = AVAudioEngine()
        do {
            try setupEngineAndTap()
            try engine.start()
            // Re-install the observer on the fresh engine instance so further
            // device swaps are still caught.
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                self?.handleConfigurationChange()
            }
            onInputDeviceChange?()
        } catch {
            NSLog("AudioRecorder: restart after config change failed: \(error)")
            isRunning = false
        }
    }

    /// Human-readable name of the system default input device
    /// (e.g. "MacBook Pro Microphone", "AirPods Pro"). Returns nil if
    /// CoreAudio can't resolve it.
    static func currentInputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }

        // kAudioObjectPropertyName returns a retained CFString; use Unmanaged
        // so ARC doesn't mishandle the reference CoreAudio hands back.
        var nameRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &nameRef)
        guard status == noErr, let name = nameRef?.takeRetainedValue() else { return nil }
        return name as String
    }
}
