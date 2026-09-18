import Foundation
import AVFoundation
import Accelerate
import CoreAudio

/// Captures microphone audio via AVAudioEngine, downmixes + resamples to
/// 16 kHz mono f32, and forwards to a consumer. Survives input device changes
/// mid-session (AirPods ↔ built-in ↔ USB).
///
/// Engine management (start, rebuild, stop, watchdog) runs on the main queue;
/// the tap runs on the audio thread and shares only `queue`-guarded state.
/// See `MicHealth` for why configuration changes don't rebuild unconditionally
/// and `MicTimeline` for why capture gaps are padded.
final class AudioRecorder {
    typealias SampleConsumer = ([Float]) async -> Void
    typealias LevelConsumer = (Float) -> Void

    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: 16_000,
                      channels: 1,
                      interleaved: false)!
    }()

    // Main-queue state.
    private var engine: AVAudioEngine = AVAudioEngine()
    private var engineActive = false
    private var engineStartUptime: TimeInterval = 0
    private var configChangeObserver: NSObjectProtocol?
    private var pendingRecovery: DispatchWorkItem?
    private var failedAttempts = 0
    private var watchdog: DispatchSourceTimer?
    private var status: MicStatus = .ok
    private(set) var isRunning = false
    /// Engine rebuilds this session (diagnostics and the live test).
    private(set) var rebuildCount = 0

    // Shared with the audio thread; guarded by `queue`.
    private let queue = DispatchQueue(label: "audio.recorder")
    private var muted = false
    private var timeline = MicTimeline(sampleRate: 16_000)
    private var lastBufferUptime: TimeInterval?
    private var awaitingFirstBuffer = false

    var onSamples: SampleConsumer?
    var onLevel: LevelConsumer?
    /// Fires on the main queue after the engine rebuilds (e.g. a default-input
    /// change: AirPods ↔ built-in ↔ USB mic). Consumers use this to re-read
    /// `activeInputDeviceName()`.
    var onInputDeviceChange: (() -> Void)?
    /// Fires on the main queue when capture health changes.
    var onStatus: ((MicStatus) -> Void)?

    /// UID of the device to capture from; nil follows the system default.
    /// Set before `start()`. A UID that is not currently attached is ignored
    /// (logged) so a stale preference never blocks recording.
    var preferredDeviceUID: String?

    func start() throws {
        try Self.onMain {
            guard !isRunning else { return }
            try startEngine()
            isRunning = true
            startWatchdog()
        }
    }

    func setMuted(_ muted: Bool) {
        queue.sync { self.muted = muted }
    }

    func stop() {
        Self.onMain {
            guard isRunning else { return }
            isRunning = false
            pendingRecovery?.cancel()
            pendingRecovery = nil
            watchdog?.cancel()
            watchdog = nil
            teardownEngine()
        }
    }

    // MARK: – Engine lifecycle (main queue)

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        applyPreferredDevice(to: input)
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0,
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone available."])
        }
        // The converter belongs to this engine's tap, so a rebuild never
        // swaps it under a buffer that is still being converted.
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, time in
            self?.handleInputBuffer(buffer, at: time, converter: converter,
                                    inputSampleRate: hwFormat.sampleRate)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        engineActive = true
        engineStartUptime = ProcessInfo.processInfo.systemUptime
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self, weak engine] _ in
            // Retired engines can still post; only the live one counts.
            guard let self, let engine, engine === self.engine else { return }
            self.scheduleRecovery(after: MicHealth.debounce, reason: "configuration change")
        }
    }

    private func teardownEngine() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        guard engineActive else { return }
        engineActive = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Coalesces: while one recovery is pending, further triggers are dropped.
    private func scheduleRecovery(after delay: TimeInterval, reason: String) {
        guard isRunning, pendingRecovery == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.recover(reason: reason) }
        pendingRecovery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func recover(reason: String) {
        pendingRecovery = nil
        guard isRunning else { return }
        let sinceBuffer = secondsSinceLastBuffer()
        guard MicHealth.needsRebuild(engineRunning: engineActive && engine.isRunning,
                                     secondsSinceLastBuffer: sinceBuffer,
                                     onPreferredDevice: isOnIntendedDevice()) else {
            Log.recorder.notice("\(reason, privacy: .public): mic still delivering, no rebuild")
            return
        }
        rebuildCount += 1
        Log.recorder.notice("\(reason, privacy: .public): rebuilding mic engine (#\(self.rebuildCount, privacy: .public))")
        setStatus(.recovering(silentSeconds: Int(sinceBuffer ?? 0)))
        queue.sync { awaitingFirstBuffer = true }
        teardownEngine()
        do {
            try startEngine()
            failedAttempts = 0
            onInputDeviceChange?()
        } catch {
            failedAttempts += 1
            let delay = MicHealth.retryDelay(afterFailedAttempts: failedAttempts)
            Log.recorder.error("mic rebuild failed (attempt \(self.failedAttempts, privacy: .public)): \(error.localizedDescription, privacy: .public); retrying in \(delay, privacy: .public)s")
            scheduleRecovery(after: delay, reason: "retry")
        }
    }

    /// Once a second: rebuild an engine that stopped delivering buffers, and
    /// keep the UI's silent-seconds count current while recovering.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            let sinceBuffer = self.secondsSinceLastBuffer()
            let sinceStart = ProcessInfo.processInfo.systemUptime - self.engineStartUptime
            if case .recovering = self.status, let silent = sinceBuffer {
                self.setStatus(.recovering(silentSeconds: Int(silent)))
            }
            if self.engineActive,
               MicHealth.isStalled(secondsSinceEngineStart: sinceStart, secondsSinceLastBuffer: sinceBuffer) {
                self.scheduleRecovery(after: 0, reason: "no mic audio for \(Int(sinceBuffer ?? sinceStart))s")
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func setStatus(_ new: MicStatus) {
        guard new != status else { return }
        status = new
        onStatus?(new)
    }

    private func secondsSinceLastBuffer() -> TimeInterval? {
        queue.sync { lastBufferUptime }.map { ProcessInfo.processInfo.systemUptime - $0 }
    }

    /// Whether the engine's input unit is on the device it should be: the
    /// attached preferred device, else the current system default (so a
    /// default-input change, or the preferred mic being unplugged, rebuilds
    /// even while the old device still delivers).
    private func isOnIntendedDevice() -> Bool {
        guard let unit = engine.inputNode.audioUnit,
              let current = Self.effectiveInputDevice(of: unit) else { return true }
        if let preferred = InputDeviceSelection.resolve(preferredUID: preferredDeviceUID,
                                                        available: Self.availableInputDevices()) {
            return current == preferred.id
        }
        return Self.defaultInputDeviceID().map { $0 == current } ?? true
    }

    private static func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync { try body() }
    }

    // MARK: – Buffers (audio thread)

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer,
                                   at time: AVAudioTime,
                                   converter: AVAudioConverter,
                                   inputSampleRate: Double) {
        // Level metering (pre-mute so user sees their voice level).
        if let ch = buffer.floatChannelData?[0] {
            let n = vDSP_Length(buffer.frameLength)
            var rms: Float = 0
            vDSP_rmsqv(ch, 1, &rms, n)
            DispatchQueue.main.async { [weak self] in self?.onLevel?(rms) }
        }

        var samples: [Float]
        if queue.sync(execute: { muted }) {
            // Muted: emit silence (preserves timing).
            let count = Int(Double(buffer.frameLength) * targetFormat.sampleRate / inputSampleRate)
            samples = [Float](repeating: 0, count: max(1, count))
        } else {
            let ratio = targetFormat.sampleRate / inputSampleRate
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
            guard status != .error, let src = out.floatChannelData?[0], out.frameLength > 0 else { return }
            samples = Array(UnsafeBufferPointer(start: src, count: Int(out.frameLength)))
        }

        let hostSeconds = time.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: time.hostTime)
            : AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let (padding, recovered) = queue.sync { () -> (Int, Bool) in
            let padding = timeline.padding(beforeBufferAt: hostSeconds)
            timeline.didWrite(padding + samples.count)
            lastBufferUptime = ProcessInfo.processInfo.systemUptime
            defer { awaitingFirstBuffer = false }
            return (padding, awaitingFirstBuffer)
        }
        if padding > 0 {
            Log.recorder.notice("padding mic stem with \(Double(padding) / 16_000, format: .fixed(precision: 2), privacy: .public)s of silence")
            samples = [Float](repeating: 0, count: padding) + samples
        }
        if recovered {
            DispatchQueue.main.async { [weak self] in self?.setStatus(.ok) }
        }
        Task { await onSamples?(samples) }
    }

    // MARK: – Device selection

    /// Points the input node's underlying HAL unit at the preferred device.
    /// Must run before the first `inputFormat(forBus:)` query, which is what
    /// makes AVAudioEngine instantiate the unit for the chosen device. Skips
    /// the set when the unit is already there: every set posts another
    /// configuration change.
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
        if Self.currentDevice(of: unit) == device.id {
            Log.recorder.notice("capturing from \(device.name, privacy: .public) (already selected)")
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

    private static func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &deviceID, &size)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    /// The physical mic behind the unit. Following the system default,
    /// AVAudioEngine sits on a private `CADefaultDeviceAggregate-…` device that
    /// tracks the default input; its active input sub-device is the real mic.
    private static func effectiveInputDevice(of unit: AudioUnit) -> AudioDeviceID? {
        guard let device = currentDevice(of: unit) else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return device   // not an aggregate
        }
        var subDevices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &subDevices) == noErr else {
            return device
        }
        return subDevices.first { inputChannelCount($0) > 0 } ?? device
    }

    /// Name of the device this recorder is actually capturing from: the
    /// preferred device when it was applied, else the system default.
    func activeInputDeviceName() -> String? {
        if let unit = engine.inputNode.audioUnit,
           let deviceID = Self.effectiveInputDevice(of: unit),
           let name = Self.deviceName(deviceID) {
            return name
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
        defaultInputDeviceID().flatMap(deviceName)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
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
        return status == noErr && deviceID != 0 ? deviceID : nil
    }
}
