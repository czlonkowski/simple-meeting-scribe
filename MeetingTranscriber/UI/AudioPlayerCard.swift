import SwiftUI
import AVFoundation
import Observation

/// Small `@Observable` wrapper around `AVAudioPlayer`. Exposes play/pause,
/// current time, duration, and a `seek(to:)` hook so the transcript list can
/// jump to a segment timestamp on click.
@MainActor
@Observable
final class TranscriptAudioPlayer {
    private var player: AVAudioPlayer?
    private var tickerTask: Task<Void, Never>?

    var url: URL?
    var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
    var isPlaying: Bool = false

    func load(url newURL: URL) {
        guard url != newURL else { return }
        unload()
        do {
            let p = try AVAudioPlayer(contentsOf: newURL)
            p.prepareToPlay()
            player = p
            url = newURL
            duration = p.duration
            currentTime = 0
        } catch {
            Log.recorder.error("audio load failed: \(String(describing: error), privacy: .public)")
        }
    }

    func unload() {
        stopTicker()
        player?.stop()
        player = nil
        url = nil
        duration = 0
        currentTime = 0
        isPlaying = false
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTicker()
        } else {
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(seconds, player.duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    private func startTicker() {
        stopTicker()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                await MainActor.run {
                    guard let self, let p = self.player else { return }
                    self.currentTime = p.currentTime
                    if !p.isPlaying {
                        self.isPlaying = false
                        self.tickerTask?.cancel()
                    }
                }
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
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
