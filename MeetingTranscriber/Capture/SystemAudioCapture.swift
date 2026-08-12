import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import Accelerate

/// Captures system audio from the main display using ScreenCaptureKit.
/// Delivers resampled 16 kHz mono f32 samples to the consumer.
///
/// Config mirrors the one used by `silverstein/minutes` (known-working on
/// macOS 14+/15): `SCRecordingOutput`-friendly video stub + `.audio` output
/// only — no `.screen` or `.microphone` output types.
///
/// ## Deafness recovery
///
/// An `SCStream` can keep delivering buffers at full rate while silently
/// dropping one application's audio: no error, no `didStopWithError`, no change
/// in stream state. A 3h08m meeting on 2026-08-12 lost ~2h of the remote
/// participants exactly that way — every buffer arrived on time and every
/// sample in it was zero, while the meeting was audibly playing in Arc. The
/// capture even kept recording *other* apps (QuickLook previews) throughout, so
/// only the per-application attribution had broken.
///
/// So the stream's own health signals can't be trusted, and this class watches
/// its output instead. Two independent triggers, both ending in the same
/// escalation ladder (`SystemAudioHealth`):
///
///   * **Audio device changes** — the observed drops each followed CoreAudio
///     client churn by a few seconds, so a debounced device-change listener
///     refreshes the content filter proactively.
///   * **Digital silence** — a backstop for anything the first trigger misses.
///
/// A filter refresh is gapless. A stream rebuild is not, so its downtime is
/// reported through `onGap` and padded into the stem: the voice and system
/// stems are merged by timestamp downstream, and an unpadded one-second gap
/// desyncs the entire remainder of the transcript.
/// Unchecked `Sendable` because the class confines its own mutable state:
/// capture and health fields are touched only on `outputQueue`, recovery
/// bookkeeping only on `recoveryQueue`.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias SampleConsumer = ([Float]) async -> Void
    typealias LevelConsumer = (Float) -> Void

    var onSamples: SampleConsumer?
    var onLevel: LevelConsumer?
    /// Wall-clock seconds the stream was down across a rebuild. The consumer
    /// must pad the stem with that much silence to keep it aligned with the mic.
    /// Always delivered before the first sample captured after the rebuild.
    var onGap: ((TimeInterval) async -> Void)?
    /// Live capture health for the recording UI. Delivered on the main queue.
    var onStatus: ((SystemAudioStatus) -> Void)?

    private var stream: SCStream?
    private let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private let outputQueue = DispatchQueue(label: "sc.audio.out", qos: .userInteractive)
    private var didLogFirstCallback = false
    private var sampleCount = 0

    // MARK: Recovery state
    /// Mutated only on `outputQueue`, from the sample callback.
    private var health = SystemAudioHealth()
    private var lastReportedStatus: SystemAudioStatus = .ok
    /// Set on `outputQueue` after a rebuild; flushed ahead of the next samples.
    private var pendingGapSeconds: TimeInterval?

    private let recoveryQueue = DispatchQueue(label: "sc.audio.recovery")
    private var isRecovering = false
    private var deviceChangeDebounce: DispatchWorkItem?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private static let deviceChangeDebounceSeconds: TimeInterval = 4

    private static let watchedDeviceProperties: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDevices
    ]

    // MARK: Lifecycle

    func start(preferredBundleID _: String) async throws {
        let stream = try await openStream()
        self.stream = stream
        outputQueue.async {
            self.health = SystemAudioHealth()
            self.lastReportedStatus = .ok
            self.pendingGapSeconds = nil
            self.didLogFirstCallback = false
            self.sampleCount = 0
        }
        installDeviceListeners()
        Log.systemAudio.notice("stream started")
    }

    func stop() async {
        removeDeviceListeners()
        recoveryQueue.sync { deviceChangeDebounce?.cancel(); deviceChangeDebounce = nil }
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            Log.systemAudio.error("stopCapture failed: \(error.localizedDescription, privacy: .public)")
        }
        self.stream = nil
        self.converter = nil
        self.lastInputFormat = nil
    }

    /// Build and start a stream. Shared by the initial start and every rebuild,
    /// so a rebuilt stream is configured identically to the original.
    private func openStream() async throws -> SCStream {
        let filter = try await Self.makeDisplayFilter()
        let stream = SCStream(filter: filter,
                              configuration: Self.makeConfiguration(),
                              delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        return stream
    }

    /// Freshly fetched shareable content every time — a stale snapshot is the
    /// prime suspect for the attribution failure this class recovers from.
    private static func makeDisplayFilter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No capturable display."])
        }
        // Match minutes' filter exactly: empty excludes + empty exceptingWindows.
        return SCContentFilter(display: display,
                               excludingApplications: [],
                               exceptingWindows: [])
    }

    private static func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.showsCursor = false
        return config
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if !didLogFirstCallback {
            didLogFirstCallback = true
            Log.systemAudio.notice("first stream callback (type=\(type.rawValue, privacy: .public))")
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
            Log.systemAudio.notice("converter input format = \(String(describing: inputFormat), privacy: .public) (mastering/.max)")
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

        // Peak magnitude serves double duty: the level meter wants RMS, but
        // deafness detection needs the exact-zero test — an all-zero buffer is
        // dropped audio, whereas a quiet room still has a noise floor.
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(count))
        vDSP_maxmgv(ch, 1, &peak, vDSP_Length(count))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(rms) }

        let samples = Array(UnsafeBufferPointer(start: ch, count: count))
        let previousCount = sampleCount
        sampleCount += count

        let action = health.ingest(frames: count,
                                   sampleRate: targetFormat.sampleRate,
                                   isSilent: peak == 0)
        reportStatus(health.status)

        // Minute-by-minute heartbeat recording whether audio is actually
        // arriving. The 2026-08-12 incident had to be reconstructed from
        // CoreAudio internals because this app's own logs said nothing; this
        // line is what makes the next one readable straight from the app.
        let heartbeat = Int(targetFormat.sampleRate) * 60
        if previousCount / heartbeat != sampleCount / heartbeat {
            Log.systemAudio.notice("""
                \(self.sampleCount / Int(self.targetFormat.sampleRate), privacy: .public)s captured, \
                peak=\(peak, format: .fixed(precision: 4), privacy: .public), \
                silentRun=\(Int(self.health.silentSeconds), privacy: .public)s, \
                recoveries=\(self.health.recoveryAttempts, privacy: .public)
                """)
        }

        let gap = pendingGapSeconds
        pendingGapSeconds = nil
        Task { [weak self] in
            // Ordered inside one task so the pad can never land after the
            // samples it is supposed to precede.
            if let gap { await self?.onGap?(gap) }
            await self?.onSamples?(samples)
        }

        switch action {
        case .none:
            break
        case .refreshFilter:
            Log.systemAudio.error("""
                no system audio for \(Int(self.health.silentSeconds), privacy: .public)s \
                — refreshing content filter
                """)
            beginRecovery(.refreshFilter)
        case .restartStream:
            Log.systemAudio.error("still no system audio after a filter refresh — rebuilding stream")
            beginRecovery(.restartStream)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Never observed firing for the deafness case, but if the stream does
        // die outright, rebuild rather than silently recording nothing.
        Log.systemAudio.error("stopped with error \(error.localizedDescription, privacy: .public)")
        beginRecovery(.restartStream)
    }

    // MARK: Recovery

    private func reportStatus(_ status: SystemAudioStatus) {
        guard status != lastReportedStatus else { return }
        lastReportedStatus = status
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }

    /// Serialize recovery: the device-change and silence triggers can fire at
    /// once, and overlapping rebuilds would lose audio rather than restore it.
    /// `isRecovering` is confined to `recoveryQueue`, so this is safe to call
    /// from the sample callback, the debounce timer, or the stream delegate.
    private func beginRecovery(_ action: SystemAudioHealth.Action) {
        guard action != .none else { return }
        recoveryQueue.async { [weak self] in
            guard let self, !self.isRecovering else { return }
            self.isRecovering = true
            DispatchQueue.main.async { self.onStatus?(.recovering) }
            Task {
                switch action {
                case .refreshFilter: await self.refreshContentFilter()
                case .restartStream: await self.rebuildStream()
                case .none: break
                }
                // Force the next real status past `reportStatus`'s change
                // filter, so the UI learns the outcome instead of sitting on
                // `.recovering` forever.
                self.outputQueue.async { self.lastReportedStatus = .recovering }
                self.recoveryQueue.async { self.isRecovering = false }
            }
        }
    }

    /// Gapless recovery: swap in a filter built from fresh shareable content
    /// without tearing the stream down.
    private func refreshContentFilter() async {
        guard let stream else { return }
        do {
            let filter = try await Self.makeDisplayFilter()
            try await stream.updateContentFilter(filter)
            Log.systemAudio.notice("content filter refreshed")
        } catch {
            Log.systemAudio.error("content filter refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Last resort: tear the stream down and build a new one, reporting the
    /// downtime so the stem can be padded and stay aligned with the mic.
    private func rebuildStream() async {
        let downSince = Date()
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil
        self.converter = nil
        self.lastInputFormat = nil
        do {
            let fresh = try await openStream()
            self.stream = fresh
            let gap = Date().timeIntervalSince(downSince)
            outputQueue.async {
                self.pendingGapSeconds = (self.pendingGapSeconds ?? 0) + gap
                self.health.reset()
            }
            Log.systemAudio.notice("stream rebuilt after \(gap, format: .fixed(precision: 2), privacy: .public)s of downtime")
        } catch {
            Log.systemAudio.error("stream rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Audio device listeners

    /// The observed drops each followed CoreAudio client churn within seconds,
    /// so refresh the filter whenever the audio device layout changes — this
    /// targets the trigger rather than waiting out the silence backstop.
    private func installDeviceListeners() {
        guard deviceListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleFilterRefreshAfterDeviceChange()
        }
        deviceListener = block
        for selector in Self.watchedDeviceProperties {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, recoveryQueue, block
            )
        }
    }

    private func removeDeviceListeners() {
        guard let block = deviceListener else { return }
        for selector in Self.watchedDeviceProperties {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, recoveryQueue, block
            )
        }
        deviceListener = nil
    }

    /// Device changes arrive in bursts (a Bluetooth route swap fires several
    /// properties in a row); debounce so one swap costs one refresh.
    private func scheduleFilterRefreshAfterDeviceChange() {
        deviceChangeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Log.systemAudio.notice("audio device configuration changed — refreshing content filter")
            self?.beginRecovery(.refreshFilter)
        }
        deviceChangeDebounce = work
        recoveryQueue.asyncAfter(deadline: .now() + Self.deviceChangeDebounceSeconds, execute: work)
    }

    // MARK: Buffer conversion

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
