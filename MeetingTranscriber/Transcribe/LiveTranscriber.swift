import Foundation
import AVFoundation
import FluidAudio

/// Transcribes the recording while it runs, on device, with Parakeet TDT
/// 0.6B v3 (multilingual, so Polish and English both work). Mic and system
/// audio are transcribed as separate streams, which gives the speaker for
/// free: the mic is you, system audio is everyone else.
///
/// Text arrives in chunks of about 11 seconds, 13–15 seconds after it was
/// said. It is a draft: the normal transcript after the recording stops
/// replaces it. Nothing here can stop or slow the recording, because audio
/// only reaches this class through `LiveAudioTap`, which drops audio
/// rather than wait.
actor LiveTranscriber {
    typealias TextHandler = @MainActor (LiveSpeaker, TimeInterval, String) -> Void

    private var managers: [SlidingWindowAsrManager] = []
    private var feedTasks: [Task<Void, Never>] = []
    private var updateTasks: [Task<Void, Never>] = []
    private var tap: LiveAudioTap?
    private var stopped = false

    /// Starts collecting audio from `tap` at once, then loads the model
    /// (downloading it the first time) and transcribes from that moment on,
    /// so what is said while the model loads is not lost. Returns once text
    /// can start arriving.
    func start(tap: LiveAudioTap,
               includeSystem: Bool,
               recordingStart: Date,
               onText: @escaping TextHandler) async throws {
        // Token times count from the first sample collected, which is now.
        let offset = Date().timeIntervalSince(recordingStart)
        let streams = tap.attach()
        self.tap = tap

        let models: AsrModels
        do {
            models = try await AsrModels.downloadAndLoad(version: .v3)
        } catch {
            tap.detach()
            throw error
        }
        guard !stopped else { return }

        var sources: [(AudioSource, LiveSpeaker)] = [(.microphone, .me)]
        if includeSystem { sources.append((.system, .others)) }

        var started: [(SlidingWindowAsrManager, LiveSpeaker, AsyncStream<SlidingWindowTranscriptionUpdate>)] = []
        for (source, speaker) in sources {
            let manager = SlidingWindowAsrManager(config: .streaming)
            try await manager.start(models: models, source: source)
            let updates = await manager.transcriptionUpdates
            started.append((manager, speaker, updates))
        }
        guard !stopped else {
            for (manager, _, _) in started { await manager.cleanup() }
            return
        }

        Log.live.notice("live transcript ready \(Int(Date().timeIntervalSince(recordingStart) - offset), privacy: .public)s after it was turned on at \(Int(offset), privacy: .public)s, streams=\(started.count, privacy: .public)")

        for (manager, speaker, updates) in started {
            managers.append(manager)
            let input = speaker == .me ? streams.mic : streams.system
            feedTasks.append(Task.detached(priority: .utility) {
                await Self.feed(input, to: manager)
            })
            updateTasks.append(Task.detached(priority: .utility) {
                for await update in updates {
                    let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = update.tokenTimings.first.map { offset + $0.startTime }
                        ?? update.timestamp.timeIntervalSince(recordingStart) - 13
                    await onText(speaker, start, text)
                }
            })
        }
    }

    /// Stops listening, transcribes the audio still buffered, then frees the
    /// model. Safe to call while `start` is still loading.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        tap?.detach()
        tap = nil
        for task in feedTasks { await task.value }
        for manager in managers {
            do {
                _ = try await manager.finish()
            } catch {
                Log.live.error("live transcript flush failed: \(error.localizedDescription, privacy: .public)")
            }
            await manager.cleanup()
        }
        for task in updateTasks { await task.value }
        managers = []
        feedTasks = []
        updateTasks = []
        Log.live.notice("live transcript stopped")
    }

    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: 16_000,
                                              channels: 1,
                                              interleaved: false)!

    private static func feed(_ input: AsyncStream<[Float]>, to manager: SlidingWindowAsrManager) async {
        for await samples in input {
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
            await manager.streamAudio(buffer)
        }
    }
}
