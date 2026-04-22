import SwiftUI
import AVFoundation
import Observation

/// `@Observable` playback wrapper backed by an `AVAudioEngine` with two
/// `AVAudioPlayerNode`s — one for the mic (voice) stem, one for the system-
/// audio stem. When both stems exist they play simultaneously through the
/// main mixer, so the remote party is audible on playback even though the
/// app never writes a single mixed WAV to disk.
@MainActor
@Observable
final class TranscriptAudioPlayer {
    private let engine = AVAudioEngine()
    private let voicePlayer = AVAudioPlayerNode()
    private let systemPlayer = AVAudioPlayerNode()
    private var voiceFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var tickerTask: Task<Void, Never>?

    // Each seek reschedules segments and resets the node's sampleTime to 0.
    // We add this offset back in when computing `currentTime`.
    private var scheduledStartOffset: TimeInterval = 0

    var url: URL?
    var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
    var isPlaying: Bool = false
    var hasSystemTrack: Bool { systemFile != nil }

    init() {
        engine.attach(voicePlayer)
        engine.attach(systemPlayer)
    }

    func load(voiceURL: URL, systemURL: URL? = nil) {
        guard url != voiceURL else { return }
        unload()
        do {
            let v = try AVAudioFile(forReading: voiceURL)
            voiceFile = v
            engine.connect(voicePlayer, to: engine.mainMixerNode, format: v.processingFormat)
            duration = Double(v.length) / v.processingFormat.sampleRate

            if let sURL = systemURL,
               FileManager.default.fileExists(atPath: sURL.path) {
                let s = try AVAudioFile(forReading: sURL)
                systemFile = s
                engine.connect(systemPlayer, to: engine.mainMixerNode, format: s.processingFormat)
            }

            url = voiceURL
            try engine.start()
            scheduleSegments(from: 0)
        } catch {
            Log.recorder.error("audio load failed: \(String(describing: error), privacy: .public)")
            unload()
        }
    }

    func unload() {
        stopTicker()
        voicePlayer.stop()
        systemPlayer.stop()
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(voicePlayer)
        engine.disconnectNodeOutput(systemPlayer)
        voiceFile = nil
        systemFile = nil
        url = nil
        duration = 0
        currentTime = 0
        scheduledStartOffset = 0
        isPlaying = false
    }

    func togglePlay() {
        guard voiceFile != nil else { return }
        if isPlaying {
            voicePlayer.pause()
            systemPlayer.pause()
            isPlaying = false
            stopTicker()
        } else {
            if !engine.isRunning { try? engine.start() }
            // If we ran off the end, rewind before playing again.
            if currentTime >= duration - 0.05 {
                voicePlayer.stop()
                systemPlayer.stop()
                scheduleSegments(from: 0)
                currentTime = 0
            }
            playBothNodesSynced()
            isPlaying = true
            startTicker()
        }
    }

    func seek(to seconds: TimeInterval) {
        guard voiceFile != nil else { return }
        let clamped = max(0, min(seconds, duration))
        let wasPlaying = isPlaying
        voicePlayer.stop()
        systemPlayer.stop()
        scheduleSegments(from: clamped)
        currentTime = clamped
        if wasPlaying {
            playBothNodesSynced()
        } else {
            isPlaying = false
        }
    }

    /// Kick off both player nodes at the same host time so the voice and
    /// system stems stay sample-aligned. The 50 ms lead-in gives CoreAudio
    /// enough slack to arm both nodes before the clock reaches the target.
    private func playBothNodesSynced() {
        let startTime = AVAudioTime(
            hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
        )
        voicePlayer.play(at: startTime)
        if systemFile != nil { systemPlayer.play(at: startTime) }
    }

    private func scheduleSegments(from offset: TimeInterval) {
        if let v = voiceFile { schedule(file: v, on: voicePlayer, from: offset) }
        if let s = systemFile { schedule(file: s, on: systemPlayer, from: offset) }
        scheduledStartOffset = offset
    }

    private func schedule(file: AVAudioFile,
                          on node: AVAudioPlayerNode,
                          from offset: TimeInterval) {
        let startFrame = AVAudioFramePosition(offset * file.processingFormat.sampleRate)
        let remaining = max(0, file.length - startFrame)
        guard remaining > 0 else { return }
        node.scheduleSegment(file,
                             startingFrame: startFrame,
                             frameCount: AVAudioFrameCount(remaining),
                             at: nil)
    }

    private func startTicker() {
        stopTicker()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await MainActor.run { self?.updateCurrentTime() }
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    private func updateCurrentTime() {
        guard isPlaying else { return }
        guard let nodeTime = voicePlayer.lastRenderTime,
              let playerTime = voicePlayer.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        currentTime = min(duration, scheduledStartOffset + max(0, played))
        if currentTime >= duration - 0.01 {
            voicePlayer.pause()
            systemPlayer.pause()
            isPlaying = false
            stopTicker()
        }
    }
}

struct AudioPlayerCard: View {
    @Bindable var player: TranscriptAudioPlayer

    var body: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 14) {
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(Theme.accent)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 0.01)
                    )
                    HStack {
                        Text(Self.formatTime(player.currentTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.formatTime(player.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private static func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}
