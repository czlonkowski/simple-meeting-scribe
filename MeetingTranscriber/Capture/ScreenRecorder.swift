import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit

/// Live state of screen-video capture, surfaced on AppState for the Record UI.
enum VideoCaptureStatus: Equatable {
    case off
    case recording(windowDescription: String)
    case unavailable(reason: String)
}

/// Records the meeting's browser window to an HEVC video file using a
/// dedicated SCStream + SCRecordingOutput. Deliberately separate from
/// `SystemAudioCapture`'s stream: that one is display-wide so its audio covers
/// every app; this one is scoped to a single window and captures no audio at
/// all — the WAV stems remain the only audio source of truth.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    struct StartedRecording {
        let outputURL: URL
        let startDate: Date
        let windowDescription: String   // e.g. "Arc window"
    }

    /// Fired when the stream dies mid-recording (window closed, etc.).
    /// The partial file is kept; `stop()` decides whether it's playable.
    var onInterrupted: ((Error) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var isTearingDown = false

    private static let browserBundleIDs = [
        "company.thebrowser.Browser",  // Arc
        "com.apple.Safari",
        "com.google.Chrome",
    ]

    // MARK: – Lifecycle

    /// Throws if no suitable window is found or the stream fails to start.
    /// Callers treat any throw as "continue without video".
    func start(outputURL requestedURL: URL, meeting: DetectedMeeting?) async throws -> StartedRecording {
        guard stream == nil else {
            throw NSError(domain: "ScreenRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Screen recording already running."])
        }

        guard let window = try await Self.findMeetingWindow(meeting: meeting) else {
            throw NSError(domain: "ScreenRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No meeting window found."])
        }
        let appName = window.owningApplication?.applicationName ?? "browser"
        NSLog("ScreenRecorder: capturing \(appName) window \"\(window.title ?? "?")\" (\(Int(window.frame.width))×\(Int(window.frame.height)))")

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        let pixelSize = Self.cappedPixelSize(for: window.frame.size,
                                             scale: CGFloat(filter.pointPixelScale))
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)  // ~10 fps
        config.queueDepth = 5
        config.capturesAudio = false
        config.showsCursor = true

        let recConfig = SCRecordingOutputConfiguration()
        // Prefer .mp4; some configurations only offer .mov.
        let fileType: AVFileType = recConfig.availableOutputFileTypes.contains(.mp4) ? .mp4 : .mov
        let url = fileType == .mp4
            ? requestedURL
            : requestedURL.deletingPathExtension().appendingPathExtension("mov")
        recConfig.outputURL = url
        recConfig.outputFileType = fileType
        recConfig.videoCodecType = recConfig.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
        let output = SCRecordingOutput(configuration: recConfig, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = output
        self.outputURL = url
        self.isTearingDown = false
        NSLog("ScreenRecorder: started → \(url.lastPathComponent) (\(config.width)×\(config.height), \(fileType.rawValue))")

        return StartedRecording(outputURL: url,
                                startDate: Date(),
                                windowDescription: "\(appName) window")
    }

    /// Stops capture and returns the file URL if a playable video exists,
    /// nil otherwise (junk/empty files are deleted). Safe to call when video
    /// never started.
    func stop() async -> URL? {
        let url = outputURL
        if let stream {
            isTearingDown = true
            // Bounded finalize: never let a hung SCK block stopping the recording.
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await stream.stopCapture() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(3))
                        throw CancellationError()
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch {
                NSLog("ScreenRecorder: stopCapture failed/timed out: \(error)")
            }
        }
        stream = nil
        recordingOutput = nil
        outputURL = nil

        guard let url else { return nil }
        if await Self.isPlayableVideo(url) {
            return url
        }
        NSLog("ScreenRecorder: discarding unplayable video file \(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    // MARK: – Delegates

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("ScreenRecorder: stream stopped with error \(error)")
        guard !isTearingDown else { return }
        onInterrupted?(error)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("ScreenRecorder: recording output failed \(error)")
        guard !isTearingDown else { return }
        onInterrupted?(error)
    }

    // MARK: – Window discovery

    /// Best-effort search for the window hosting the meeting:
    /// matched browser → title containing the meeting code/platform → largest
    /// window of that browser. For manual recordings (no detected meeting)
    /// tries the frontmost known browser first.
    static func findMeetingWindow(meeting: DetectedMeeting?) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let targetBundles: [String]
        if let id = meeting?.browserBundleID {
            targetBundles = [id]
        } else {
            targetBundles = orderedByFrontmost(browserBundleIDs)
        }

        for bundleID in targetBundles {
            let windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
                    && $0.isOnScreen
                    && $0.frame.width > 300 && $0.frame.height > 200  // skip palettes/popovers
            }
            guard !windows.isEmpty else { continue }
            if let meeting, let hit = bestTitleMatch(in: windows, meeting: meeting) {
                return hit
            }
            return windows.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            })
        }
        return nil
    }

    private static func orderedByFrontmost(_ bundles: [String]) -> [String] {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bundles.contains(front)
        else { return bundles }
        return [front] + bundles.filter { $0 != front }
    }

    private static func bestTitleMatch(in windows: [SCWindow], meeting: DetectedMeeting) -> SCWindow? {
        // Meeting code = last URL path segment, e.g. "abc-defg-hij" for Meet.
        let code = URLComponents(string: meeting.url)?
            .path.split(separator: "/").last.map(String.init)
        let tokens = [code, meeting.platform].compactMap { $0 }.filter { $0.count >= 3 }
        return windows.first { window in
            guard let title = window.title?.lowercased(), !title.isEmpty else { return false }
            return tokens.contains { title.contains($0.lowercased()) }
        }
    }

    // MARK: – Helpers

    /// Window points × Retina scale, downscaled so the longest side is ≤1440
    /// and both dimensions are even (HEVC requirement).
    static func cappedPixelSize(for pointSize: CGSize, scale: CGFloat) -> CGSize {
        var px = CGSize(width: max(2, pointSize.width * scale),
                        height: max(2, pointSize.height * scale))
        let cap: CGFloat = 1440
        let longest = max(px.width, px.height)
        if longest > cap {
            let ratio = cap / longest
            px = CGSize(width: px.width * ratio, height: px.height * ratio)
        }
        return CGSize(width: CGFloat(Int(px.width) & ~1),
                      height: CGFloat(Int(px.height) & ~1))
    }

    /// A file only counts if it has a video track with non-zero duration —
    /// this is the single gate deciding whether `videoFileName` ever reaches
    /// the saved document.
    private static func isPlayableVideo(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              !tracks.isEmpty,
              let duration = try? await asset.load(.duration),
              duration.seconds > 0
        else { return false }
        return true
    }
}
