import Foundation
import MicrosoftCognitiveServicesSpeech

/// One live audio stream transcribed by Azure Speech real-time recognition
/// (continuous, one locale, the glossary as a phrase list). Text arrives per
/// sentence, about 0.6 s after it ends.
///
/// The Speech SDK runs its own threads and reconnects long sessions itself.
/// `write` only copies samples into the SDK's push stream, so it never waits
/// on the network. Unchecked `Sendable`: the SDK objects are thread-safe and
/// the only mutable state is guarded by `lock`.
final class AzureLiveStream: @unchecked Sendable {
    /// Seconds since the first sample written, and the text.
    typealias TextHandler = @Sendable (TimeInterval, String) -> Void
    typealias FailureHandler = @Sendable (String) -> Void
    /// The sentence heard so far; it may still change. Nil once it is final.
    typealias PartialHandler = @Sendable (String?) -> Void

    private let push: SPXPushAudioInputStream
    private let recognizer: SPXSpeechRecognizer
    private let stopped = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finishing = false

    init(endpoint: String,
         key: String,
         locale: String,
         phrases: [String],
         onText: @escaping TextHandler,
         onPartial: @escaping PartialHandler = { _ in },
         onFailure: @escaping FailureHandler) throws {
        let config = try SPXSpeechConfiguration(endpoint: endpoint, subscription: key)
        config.speechRecognitionLanguage = locale
        guard let format = SPXAudioStreamFormat(usingPCMWithSampleRate: 16_000, bitsPerSample: 16, channels: 1),
              let push = SPXPushAudioInputStream(audioFormat: format) else {
            throw AzureLiveError.setup("could not create the audio stream")
        }
        guard let audio = SPXAudioConfiguration(streamInput: push) else {
            throw AzureLiveError.setup("could not create the audio input")
        }
        let recognizer = try SPXSpeechRecognizer(speechConfiguration: config, audioConfiguration: audio)
        if !phrases.isEmpty, let list = SPXPhraseListGrammar(recognizer: recognizer) {
            phrases.forEach(list.addPhrase)
        }
        self.push = push
        self.recognizer = recognizer

        recognizer.addRecognizingEventHandler { (_: SPXSpeechRecognizer, event: SPXSpeechRecognitionEventArgs) in
            guard let text = event.result.text, !text.isEmpty else { return }
            onPartial(text)
        }
        recognizer.addRecognizedEventHandler { (_: SPXSpeechRecognizer, event: SPXSpeechRecognitionEventArgs) in
            onPartial(nil)
            guard event.result.reason == SPXResultReason.recognizedSpeech,
                  let text = event.result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            // Offsets are in 100 ns ticks from the start of the stream.
            onText(TimeInterval(event.result.offset) / 10_000_000, text)
        }
        recognizer.addCanceledEventHandler { [weak self] (_: SPXSpeechRecognizer, event: SPXSpeechRecognitionCanceledEventArgs) in
            guard let self else { return }
            if event.reason == SPXCancellationReason.error, !self.isFinishing {
                onFailure(event.errorDetails ?? "Azure Speech error \(event.errorCode.rawValue)")
            }
            self.stopped.signal()
        }
        recognizer.addSessionStoppedEventHandler { [weak self] (_: SPXRecognizer, _: SPXSessionEventArgs) in
            self?.stopped.signal()
        }
    }

    func start() throws {
        try recognizer.startContinuousRecognition()
    }

    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            pcm[i] = Int16(max(-1, min(1, samples[i])) * Float(Int16.max))
        }
        push.write(pcm.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// Ends the stream and waits (up to `timeout`) for the text of the last
    /// sentence. Blocks; call it off the main thread.
    func finish(timeout: TimeInterval = 5) {
        lock.lock()
        let already = finishing
        finishing = true
        lock.unlock()
        guard !already else { return }
        push.close()
        _ = stopped.wait(timeout: .now() + timeout)
        try? recognizer.stopContinuousRecognition()
    }

    private var isFinishing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishing
    }

    /// Azure locale for the recording language.
    static func locale(for language: TranscriptionLanguage) -> String {
        switch language {
        case .polish: return "pl-PL"
        case .english: return "en-US"
        }
    }
}

enum AzureLiveError: LocalizedError {
    case setup(String)

    var errorDescription: String? {
        switch self {
        case .setup(let message): return "Azure Speech: \(message)"
        }
    }
}
