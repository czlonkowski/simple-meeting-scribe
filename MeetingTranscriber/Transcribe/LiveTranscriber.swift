import Foundation
import AVFoundation
import FluidAudio

/// Transcribes the recording while it runs. Mic and system audio are
/// transcribed as separate streams, which gives the speaker for free: the
/// mic is you, system audio is everyone else.
///
/// Each stream uses Azure Speech real-time recognition when an Azure Speech
/// key and endpoint are set (text about 0.6 s after each sentence), else
/// Parakeet TDT 0.6B v3 on device (text in ~11 s chunks, 13–15 s late). A
/// stream whose Azure connection fails tries Azure once more, then switches
/// to Parakeet for the rest of the recording.
///
/// It is a draft: the normal transcript after the recording stops replaces
/// it. Nothing here can stop or slow the recording, because audio only
/// reaches this class through `LiveAudioTap`, which drops audio rather than
/// wait.
actor LiveTranscriber {
    typealias TextHandler = @MainActor (LiveSpeaker, TimeInterval, String) -> Void
    typealias EngineHandler = @MainActor (LiveTranscript.Engine) -> Void
    typealias PartialHandler = @MainActor (LiveSpeaker, String?) -> Void

    struct AzureSettings: Sendable {
        let endpoint: String
        let key: String
        let locale: String
        let phrases: [String]
    }

    private enum Backend {
        case azure(AzureLiveStream)
        case parakeet(SlidingWindowAsrManager)
    }

    private var backends: [LiveSpeaker: Backend] = [:]
    /// Samples fed per stream, to place a replacement backend on the timeline.
    private var fed: [LiveSpeaker: Int] = [:]
    private var azureRetries: [LiveSpeaker: Int] = [:]
    private var feedTasks: [Task<Void, Never>] = []
    private var updateTasks: [Task<Void, Never>] = []
    private var retired: [Backend] = []
    private var parakeetModels: AsrModels?
    private var tap: LiveAudioTap?
    private var stopped = false

    private var offset: TimeInterval = 0
    private var azure: AzureSettings?
    private var onText: TextHandler = { _, _, _ in }
    private var onEngine: EngineHandler = { _ in }
    private var onPartial: PartialHandler = { _, _ in }

    /// Starts collecting audio from `tap` at once, then connects or loads
    /// the model, so what is said meanwhile is not lost. Returns once text
    /// can start arriving.
    func start(tap: LiveAudioTap,
               includeSystem: Bool,
               recordingStart: Date,
               azure: AzureSettings?,
               onText: @escaping TextHandler,
               onPartial: @escaping PartialHandler,
               onEngine: @escaping EngineHandler) async throws {
        // Times count from the first sample collected, which is now.
        offset = Date().timeIntervalSince(recordingStart)
        self.azure = azure
        self.onText = onText
        self.onEngine = onEngine
        self.onPartial = onPartial
        let streams = tap.attach()
        self.tap = tap

        var speakers: [LiveSpeaker] = [.me]
        if includeSystem { speakers.append(.others) }
        do {
            for speaker in speakers {
                backends[speaker] = try await makeBackend(for: speaker)
            }
        } catch {
            tap.detach()
            throw error
        }
        guard !stopped else { return }
        await reportEngine()
        Log.live.notice("live transcript ready \(Int(Date().timeIntervalSince(recordingStart) - self.offset), privacy: .public)s after it was turned on at \(Int(self.offset), privacy: .public)s, streams=\(speakers.count, privacy: .public)")

        for speaker in speakers {
            let input = speaker == .me ? streams.mic : streams.system
            feedTasks.append(Task.detached(priority: .utility) { [weak self] in
                for await samples in input {
                    await self?.feed(samples, from: speaker)
                }
            })
        }
    }

    /// Stops listening, transcribes the audio still buffered, then frees the
    /// engines. Safe to call while `start` is still connecting or loading.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        tap?.detach()
        tap = nil
        for task in feedTasks { await task.value }
        for backend in Array(backends.values) + retired {
            await finish(backend)
        }
        for task in updateTasks { await task.value }
        backends = [:]
        retired = []
        feedTasks = []
        updateTasks = []
        Log.live.notice("live transcript stopped")
    }

    // MARK: – Backends

    private func makeBackend(for speaker: LiveSpeaker) async throws -> Backend {
        let base = offset + Double(fed[speaker, default: 0]) / 16_000
        if let azure, azureRetries[speaker, default: 0] < 2 {
            do {
                return .azure(try makeAzure(azure, for: speaker, base: base))
            } catch {
                Log.live.error("Azure live stream setup failed, using Parakeet: \(error.localizedDescription, privacy: .public)")
                azureRetries[speaker] = 2
            }
        }
        return .parakeet(try await makeParakeet(for: speaker, base: base))
    }

    private func makeAzure(_ settings: AzureSettings, for speaker: LiveSpeaker, base: TimeInterval) throws -> AzureLiveStream {
        let onText = self.onText
        let onPartial = self.onPartial
        let stream = try AzureLiveStream(
            endpoint: settings.endpoint,
            key: settings.key,
            locale: settings.locale,
            phrases: settings.phrases,
            onText: { start, text in
                Task { await onText(speaker, base + start, text) }
            },
            onPartial: { text in
                Task { await onPartial(speaker, text) }
            },
            onFailure: { [weak self] message in
                Task { await self?.azureFailed(speaker, message: message) }
            })
        try stream.start()
        return stream
    }

    private func makeParakeet(for speaker: LiveSpeaker, base: TimeInterval) async throws -> SlidingWindowAsrManager {
        let models: AsrModels
        if let parakeetModels {
            models = parakeetModels
        } else {
            models = try await AsrModels.downloadAndLoad(version: .v3)
            parakeetModels = models
        }
        let manager = SlidingWindowAsrManager(config: .streaming)
        try await manager.loadModels(models)
        try await manager.startStreaming(source: speaker == .me ? .microphone : .system)
        let updates = await manager.transcriptionUpdates
        let onText = self.onText
        updateTasks.append(Task.detached(priority: .utility) {
            for await update in updates {
                let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                await onText(speaker, base + (update.tokenTimings.first?.startTime ?? 0), text)
            }
        })
        return manager
    }

    private func azureFailed(_ speaker: LiveSpeaker, message: String) async {
        guard !stopped, case .azure? = backends[speaker] else { return }
        await onPartial(speaker, nil)
        Log.live.error("Azure live stream failed: \(message, privacy: .public)")
        azureRetries[speaker, default: 0] += 1
        if let old = backends.removeValue(forKey: speaker) { retired.append(old) }
        do {
            backends[speaker] = try await makeBackend(for: speaker)
        } catch {
            Log.live.error("no live engine left for this stream: \(error.localizedDescription, privacy: .public)")
        }
        await reportEngine()
    }

    private func reportEngine() async {
        let usesAzure = backends.values.contains { if case .azure = $0 { return true } else { return false } }
        let usesParakeet = backends.values.contains { if case .parakeet = $0 { return true } else { return false } }
        let engine: LiveTranscript.Engine = usesAzure
            ? .azure
            : (azure != nil && usesParakeet ? .onDeviceFallback : .onDevice)
        await onEngine(engine)
    }

    private func feed(_ samples: [Float], from speaker: LiveSpeaker) async {
        fed[speaker, default: 0] += samples.count
        switch backends[speaker] {
        case .azure(let stream):
            stream.write(samples)
        case .parakeet(let manager):
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: Self.format,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
            await manager.streamAudio(buffer)
        case nil:
            break
        }
    }

    private func finish(_ backend: Backend) async {
        switch backend {
        case .azure(let stream):
            await Task.detached(priority: .utility) { stream.finish() }.value
        case .parakeet(let manager):
            do {
                _ = try await manager.finish()
            } catch {
                Log.live.error("live transcript flush failed: \(error.localizedDescription, privacy: .public)")
            }
            await manager.cleanup()
        }
    }

    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: 16_000,
                                              channels: 1,
                                              interleaved: false)!
}
