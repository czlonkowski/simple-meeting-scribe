import XCTest
import AVFoundation
import FluidAudio
@testable import MeetingTranscriber

/// Opt-in comparison of streaming engines for the live transcript. For each
/// `<name>.wav` (16 kHz mono) in LIVE_BENCH_DIR it writes
/// `<name>.<engine>.json` with the final text, processing time and audio
/// length. Score the output against `<name>.ref.txt` outside the test.
///
///     TEST_RUNNER_LIVE_BENCH_DIR=/path/dir \
///       xcodebuild … test -only-testing:MeetingTranscriberTests/LiveEngineBenchmarkTests
final class LiveEngineBenchmarkTests: XCTestCase {

    private func clips() throws -> (URL, [URL]) {
        guard let path = ProcessInfo.processInfo.environment["LIVE_BENCH_DIR"], !path.isEmpty else {
            throw XCTSkip("Set LIVE_BENCH_DIR to run the live engine benchmark")
        }
        let dir = URL(fileURLWithPath: path)
        let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return (dir, wavs)
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func write(_ dir: URL, _ clip: URL, engine: String, text: String,
                       seconds: Double, audioSeconds: Double, extra: [String: Any] = [:]) throws {
        var payload: [String: Any] = ["text": text, "processingSeconds": seconds, "audioSeconds": audioSeconds]
        payload.merge(extra) { $1 }
        let name = clip.deletingPathExtension().lastPathComponent
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: dir.appendingPathComponent("\(name).\(engine).json"))
        print("BENCH \(name) \(engine): \(String(format: "%.1f", seconds))s for \(String(format: "%.0f", audioSeconds))s audio")
    }

    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                              channels: 1, interleaved: false)!

    /// The current engine: Parakeet v3 in 11 s sliding windows.
    func testParakeetSlidingWindow() async throws {
        let (dir, wavs) = try clips()
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let configs: [(String, SlidingWindowAsrConfig)] = [
            ("parakeet-sw", .streaming),
            ("parakeet-sw6", SlidingWindowAsrConfig(chunkSeconds: 6, leftContextSeconds: 4, rightContextSeconds: 2)),
            ("parakeet-sw4", SlidingWindowAsrConfig(chunkSeconds: 4, leftContextSeconds: 6, rightContextSeconds: 2))
        ]
        for (engine, config) in configs {
        for clip in wavs {
            let audio = try samples(clip)
            let manager = SlidingWindowAsrManager(config: config)
            try await manager.loadModels(models)
            try await manager.startStreaming(source: .system)
            let updates = await manager.transcriptionUpdates
            let collector = Task { () -> [String] in
                var parts: [String] = []
                for await update in updates { parts.append(update.text) }
                return parts
            }
            let start = Date()
            for offset in stride(from: 0, to: audio.count, by: 1_600) {
                let slice = Array(audio[offset..<min(offset + 1_600, audio.count)])
                let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(slice.count))!
                buffer.frameLength = AVAudioFrameCount(slice.count)
                slice.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: slice.count) }
                await manager.streamAudio(buffer)
            }
            _ = try await manager.finish()
            let elapsed = Date().timeIntervalSince(start)
            await manager.cleanup()
            let parts = await collector.value
            try write(dir, clip, engine: engine, text: parts.joined(separator: " "),
                      seconds: elapsed, audioSeconds: Double(audio.count) / 16_000)
        }
        }
    }

    /// Nemotron multilingual streaming at two chunk sizes, language "auto".
    func testNemotronMultilingual() async throws {
        let (dir, wavs) = try clips()
        for chunkMs in [1120, 2240] {
            let shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
                languageCode: "auto", chunkMs: chunkMs)
            for language in ["auto", "pl-PL"] {
                for clip in wavs {
                    let audio = try samples(clip)
                    let manager = StreamingNemotronMultilingualAsrManager()
                    try await manager.loadFromShared(shared)
                    await manager.setLanguage(language)
                    let step = chunkMs * 16
                    var chunkTimes: [Double] = []
                    let start = Date()
                    for offset in stride(from: 0, to: audio.count, by: step) {
                        let t = Date()
                        _ = try await manager.process(samples: Array(audio[offset..<min(offset + step, audio.count)]))
                        chunkTimes.append(Date().timeIntervalSince(t))
                    }
                    let text = try await manager.finish()
                    let elapsed = Date().timeIntervalSince(start)
                    let detected = await manager.detectedLanguage() ?? "?"
                    await manager.cleanup()
                    try write(dir, clip, engine: "nemotron-\(chunkMs)-\(language)", text: text,
                              seconds: elapsed, audioSeconds: Double(audio.count) / 16_000,
                              extra: ["maxChunkSeconds": chunkTimes.max() ?? 0, "detectedLanguage": detected])
                }
            }
        }
    }
}
