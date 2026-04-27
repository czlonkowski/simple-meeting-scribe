import Foundation
import AVFoundation

struct RecordedStems {
    let voiceURL: URL
    let systemURL: URL?
}

/// Owns an AudioRecorder + SystemAudioCapture + StemWriter for one session.
final class RecordingCoordinator {
    private let mic = AudioRecorder()
    private let system = SystemAudioCapture()
    private var writer: StemWriter?
    private var captureSystem = false

    func start(captureSystemAudio: Bool,
               onMicLevel: @escaping (Float) -> Void,
               onSystemLevel: @escaping (Float) -> Void,
               onInputDeviceChange: (() -> Void)? = nil) async throws {
        let baseURL = Self.makeBaseURL()
        let writer = try StemWriter(baseURL: baseURL)
        self.writer = writer
        self.captureSystem = captureSystemAudio

        mic.onSamples = { [weak writer] samples in
            guard let writer else { return }
            await writer.appendMic(samples)
        }
        mic.onLevel = onMicLevel
        mic.onInputDeviceChange = onInputDeviceChange
        try mic.start()

        if captureSystemAudio {
            system.onSamples = { [weak writer] samples in
                guard let writer else { return }
                await writer.appendSystem(samples)
            }
            system.onLevel = onSystemLevel
            do {
                try await system.start(preferredBundleID: "company.thebrowser.Browser")
            } catch {
                NSLog("System audio capture failed (continuing mic-only): \(error)")
                self.captureSystem = false
            }
        }
    }

    func setMicMuted(_ muted: Bool) {
        mic.setMuted(muted)
        Task { await writer?.setMicMuted(muted) }
    }

    func stop() async throws -> RecordedStems {
        mic.stop()
        if captureSystem { await system.stop() }
        guard let writer else {
            throw NSError(domain: "RecordingCoordinator", code: 1)
        }
        let urls = await writer.close()
        self.writer = nil
        return RecordedStems(voiceURL: urls.voice, systemURL: urls.system)
    }

    private static func makeBaseURL() -> URL {
        let dir = TranscriptStore.shared.recordingsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = f.string(from: Date())
        return dir.appendingPathComponent(name) // no extension; StemWriter adds .voice.wav / .system.wav
    }
}
