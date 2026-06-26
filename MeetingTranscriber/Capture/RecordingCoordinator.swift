import Foundation
import AVFoundation

struct RecordedStems {
    let voiceURL: URL
    let systemURL: URL?
    /// Validated, playable screen recording — nil when video was off, failed,
    /// or produced an unplayable file.
    let videoURL: URL?
    /// Seconds the video started after the mic stem (supports mid-meeting start).
    let videoStartOffset: TimeInterval?
}

/// Owns an AudioRecorder + SystemAudioCapture + ScreenRecorder + StemWriter
/// for one session.
final class RecordingCoordinator {
    private let mic = AudioRecorder()
    private let system = SystemAudioCapture()
    private let screen = ScreenRecorder()
    private var writer: StemWriter?
    private var captureSystem = false
    private var baseURL: URL?
    private var micStartDate: Date?
    private var videoStartOffset: TimeInterval?
    private var onVideoStatus: ((VideoCaptureStatus) -> Void)?

    func start(captureSystemAudio: Bool,
               recordScreen: Bool,
               meeting: DetectedMeeting?,
               onMicLevel: @escaping (Float) -> Void,
               onSystemLevel: @escaping (Float) -> Void,
               onInputDeviceChange: (() -> Void)? = nil,
               onVideoStatus: ((VideoCaptureStatus) -> Void)? = nil) async throws {
        let baseURL = Self.makeBaseURL()
        let writer = try StemWriter(baseURL: baseURL)
        self.writer = writer
        self.baseURL = baseURL
        self.captureSystem = captureSystemAudio
        self.onVideoStatus = onVideoStatus

        mic.onSamples = { [weak writer] samples in
            guard let writer else { return }
            await writer.appendMic(samples)
        }
        mic.onLevel = onMicLevel
        mic.onInputDeviceChange = onInputDeviceChange
        try mic.start()
        micStartDate = Date()

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

        if recordScreen {
            await startVideo(meeting: meeting)
        }
    }

    /// Start the screen recording — at session start or any time mid-recording.
    /// Failure degrades to audio-only (same philosophy as system audio); a
    /// failed attempt leaves `videoStartOffset` nil, so retrying is allowed.
    func startVideo(meeting: DetectedMeeting?) async {
        guard videoStartOffset == nil,                  // one video segment per session
              let baseURL, let micStartDate else { return }
        do {
            let started = try await screen.start(
                outputURL: baseURL.appendingPathExtension("video.mp4"),
                meeting: meeting
            )
            videoStartOffset = started.startDate.timeIntervalSince(micStartDate)
            screen.onInterrupted = { [weak self] error in
                NSLog("Screen recording interrupted (audio continues): \(error)")
                self?.onVideoStatus?(.unavailable(reason: "Window closed"))
            }
            onVideoStatus?(.recording(windowDescription: started.windowDescription))
        } catch {
            NSLog("Screen recording failed (continuing without video): \(error)")
            onVideoStatus?(.unavailable(reason: error.localizedDescription))
        }
    }

    func setMicMuted(_ muted: Bool) {
        mic.setMuted(muted)
        Task { await writer?.setMicMuted(muted) }
    }

    func stop() async throws -> RecordedStems {
        mic.stop()
        if captureSystem { await system.stop() }
        let videoURL = await screen.stop()
        guard let writer else {
            throw NSError(domain: "RecordingCoordinator", code: 1)
        }
        let urls = await writer.close()
        self.writer = nil
        return RecordedStems(voiceURL: urls.voice,
                             systemURL: urls.system,
                             videoURL: videoURL,
                             videoStartOffset: videoURL != nil ? videoStartOffset : nil)
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
