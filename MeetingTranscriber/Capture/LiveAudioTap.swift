import Foundation

/// Hands a copy of the recorded samples to the live transcript.
///
/// The capture callbacks call `send` on every buffer. It never waits: each
/// source has a bounded stream that drops the oldest buffers when the
/// transcriber falls behind, so a slow or stuck transcriber can't hold up
/// the recording. With nothing attached, `send` does nothing.
///
/// Unchecked `Sendable` because the lock guards all mutable state.
final class LiveAudioTap: @unchecked Sendable {
    enum Source: Sendable { case mic, system }

    /// About 2 minutes of 16 kHz audio in typical capture buffer sizes
    /// (mic ~1 400 samples, system ~1 000). Past that, old audio is dropped.
    static let bufferLimit = 2_000

    private let lock = NSLock()
    private var mic: AsyncStream<[Float]>.Continuation?
    private var system: AsyncStream<[Float]>.Continuation?
    private var micMuted = false

    /// Starts copying samples. Each returned stream ends on `detach()`.
    func attach() -> (mic: AsyncStream<[Float]>, system: AsyncStream<[Float]>) {
        let (micStream, micCont) = AsyncStream.makeStream(of: [Float].self,
                                                         bufferingPolicy: .bufferingNewest(Self.bufferLimit))
        let (systemStream, systemCont) = AsyncStream.makeStream(of: [Float].self,
                                                               bufferingPolicy: .bufferingNewest(Self.bufferLimit))
        lock.lock()
        mic?.finish()
        system?.finish()
        mic = micCont
        system = systemCont
        lock.unlock()
        return (micStream, systemStream)
    }

    func detach() {
        lock.lock()
        mic?.finish()
        system?.finish()
        mic = nil
        system = nil
        lock.unlock()
    }

    /// Muted mic audio reaches the transcript as silence, so what you say
    /// while muted is not transcribed and the timeline stays in step.
    func setMicMuted(_ muted: Bool) {
        lock.lock()
        micMuted = muted
        lock.unlock()
    }

    func send(_ samples: [Float], from source: Source) {
        lock.lock()
        let target = source == .mic ? mic : system
        let silence = source == .mic && micMuted
        lock.unlock()
        guard let target else { return }
        target.yield(silence ? [Float](repeating: 0, count: samples.count) : samples)
    }

    /// The system stream lost audio while it was rebuilt. Silence of the
    /// same length keeps later live timestamps in step with the recording.
    func sendSilence(seconds: TimeInterval, from source: Source, sampleRate: Double = 16_000) {
        let total = Int((seconds * sampleRate).rounded())
        guard total > 0 else { return }
        let chunk = Int(sampleRate)
        var remaining = total
        while remaining > 0 {
            let n = min(chunk, remaining)
            send([Float](repeating: 0, count: n), from: source)
            remaining -= n
        }
    }
}
