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

    /// UID of the device to capture from; nil follows the system default.
    /// Set before `start()`. A UID that is not currently attached is ignored
    /// (logged) so a stale preference never blocks recording.
    var preferredDeviceUID: String?

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
        applyPreferredDevice(to: input)
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
            Log.recorder.error("restart after config change failed: \(error.localizedDescription, privacy: .public)")
            isRunning = false
        }
    }

    // MARK: – Device selection

    /// Points the input node's underlying HAL unit at the preferred device.
    /// Must run before the first `inputFormat(forBus:)` query, which is what
    /// makes AVAudioEngine instantiate the unit for the chosen device.
    private func applyPreferredDevice(to input: AVAudioInputNode) {
        let available = Self.availableInputDevices()
        guard let device = InputDeviceSelection.resolve(preferredUID: preferredDeviceUID,
                                                        available: available) else {
            if let uid = preferredDeviceUID, !uid.isEmpty {
                Log.recorder.notice("preferred input \(uid, privacy: .public) not attached; using system default")
            }
            return
        }
        guard let unit = input.audioUnit else {
            Log.recorder.error("input node has no audio unit; cannot select \(device.name, privacy: .public)")
            return
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status == noErr {
            Log.recorder.notice("capturing from \(device.name, privacy: .public)")
        } else {
            Log.recorder.error("selecting \(device.name, privacy: .public) failed (OSStatus \(status, privacy: .public)); using system default")
        }
    }

    /// Name of the device this recorder is actually capturing from: the
    /// preferred device when it was applied, else the system default.
    func activeInputDeviceName() -> String? {
        if let unit = engine.inputNode.audioUnit {
            var deviceID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &deviceID, &size)
            if status == noErr, deviceID != 0, let name = Self.deviceName(deviceID) {
                return name
            }
        }
        return Self.currentInputDeviceName()
    }

    /// Calls `handler` on the main queue whenever CoreAudio's device list
    /// changes (plug/unplug, Bluetooth connect). Returns a token; keep it
    /// alive for as long as the observation should run.
    static func observeDeviceListChanges(_ handler: @escaping () -> Void) -> AnyObject {
        let addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let observer = DeviceListObserver(address: addr) { handler() }
        return observer
    }

    private final class DeviceListObserver {
        private var address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock

        init(address: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
            self.address = address
            self.block = { _, _ in handler() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &self.address, .main, block)
        }

        deinit {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, .main, block)
        }
    }

    /// Every attached device with at least one input channel, in HAL order.
    static func availableInputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = deviceUID(id),
                  let name = deviceName(id) else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioObjectPropertyName)
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       selector: AudioObjectPropertySelector) -> String? {
        // CoreAudio hands back a retained CFString; Unmanaged keeps ARC honest.
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref)
        guard status == noErr, let value = ref?.takeRetainedValue() else { return nil }
        return value as String
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
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceName(deviceID)
    }
}
