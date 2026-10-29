import XCTest
import AVFoundation
@testable import MeetingTranscriber

final class AzureLiveStreamTests: XCTestCase {

    func testLocaleFollowsRecordingLanguage() {
        XCTAssertEqual(AzureLiveStream.locale(for: .polish), "pl-PL")
        XCTAssertEqual(AzureLiveStream.locale(for: .english), "en-US")
    }

    /// Opt-in round trip against the real service, at 4× real time:
    ///
    ///     TEST_RUNNER_AZURE_SPEECH_KEY=… TEST_RUNNER_AZURE_SPEECH_ENDPOINT=https://<resource>.cognitiveservices.azure.com/ \
    ///     TEST_RUNNER_AZURE_LIVE_AUDIO=/path/english.wav \
    ///       xcodebuild … test -only-testing:MeetingTranscriberTests/AzureLiveStreamTests
    func testStreamsTimedEnglishText() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["AZURE_SPEECH_KEY"], !key.isEmpty,
              let endpoint = env["AZURE_SPEECH_ENDPOINT"], !endpoint.isEmpty,
              let path = env["AZURE_LIVE_AUDIO"], !path.isEmpty else {
            throw XCTSkip("Set AZURE_SPEECH_KEY, AZURE_SPEECH_ENDPOINT and AZURE_LIVE_AUDIO to run the live Azure test")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

        let collected = Collected()
        let stream = try AzureLiveStream(endpoint: endpoint, key: key, locale: "en-US", phrases: ["n8n"],
                                         onText: { start, text in collected.add(start, text) },
                                         onFailure: { collected.fail($0) })
        try stream.start()
        for offset in stride(from: 0, to: samples.count, by: 1_600) {
            stream.write(Array(samples[offset..<min(offset + 1_600, samples.count)]))
            try await Task.sleep(for: .milliseconds(25))
        }
        await Task.detached { stream.finish(timeout: 15) }.value

        let (parts, failure) = collected.snapshot()
        XCTAssertNil(failure)
        XCTAssertFalse(parts.isEmpty)
        XCTAssertTrue(zip(parts, parts.dropFirst()).allSatisfy { $0.0 <= $1.0 })
        print("AZURE LIVE:", parts.map { "[\(Int($0.0))s] \($0.1)" }.joined(separator: " "))
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [(TimeInterval, String)] = []
    private var failure: String?
    func add(_ start: TimeInterval, _ text: String) { lock.lock(); parts.append((start, text)); lock.unlock() }
    func fail(_ message: String) { lock.lock(); failure = message; lock.unlock() }
    func snapshot() -> ([(TimeInterval, String)], String?) { lock.lock(); defer { lock.unlock() }; return (parts, failure) }
}

/// Opt-in: with a wrong key, each stream retries Azure once and then
/// switches to Parakeet. Needs the network and the Parakeet models.
///
///     TEST_RUNNER_AZURE_SPEECH_ENDPOINT=https://<resource>.cognitiveservices.azure.com/ \
///       xcodebuild … test -only-testing:MeetingTranscriberTests/LiveTranscriberFallbackTests
final class LiveTranscriberFallbackTests: XCTestCase {

    @MainActor
    func testWrongAzureKeyFallsBackToParakeet() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["AZURE_SPEECH_ENDPOINT"], !endpoint.isEmpty else {
            throw XCTSkip("Set AZURE_SPEECH_ENDPOINT to run the fallback test")
        }
        let tap = LiveAudioTap()
        let transcriber = LiveTranscriber()
        var engines: [LiveTranscript.Engine] = []
        try await transcriber.start(
            tap: tap, includeSystem: false, recordingStart: Date(),
            azure: .init(endpoint: endpoint, key: "wrong-key-for-test", locale: "pl-PL", phrases: []),
            onText: { _, _, _ in }, onPartial: { _, _ in },
            onEngine: { engines.append($0) })
        XCTAssertEqual(engines.last, .azure)
        let deadline = Date().addingTimeInterval(60)
        while engines.last != .onDeviceFallback, Date() < deadline {
            tap.send([Float](repeating: 0, count: 1_600), from: .mic)
            try await Task.sleep(for: .milliseconds(100))
        }
        await transcriber.stop()
        XCTAssertEqual(engines.last, .onDeviceFallback)
        print("FALLBACK engines:", engines)
    }
}
