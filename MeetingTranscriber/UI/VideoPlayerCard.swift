import SwiftUI
import AVKit

/// Card shown instead of `AudioPlayerCard` when a transcript has a screen
/// recording. The video view is a passive follower — all transport state
/// (play/pause/seek) lives in `TranscriptAudioPlayer`, which keeps the muted
/// AVPlayer in sync with the audio stems.
struct VideoPlayerCard: View {
    @Bindable var player: TranscriptAudioPlayer

    var body: some View {
        GlassCard(padding: 14) {
            VStack(spacing: 12) {
                if let avPlayer = player.videoPlayer {
                    VideoSurface(player: avPlayer)
                        .frame(maxWidth: .infinity)
                        .frame(height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                PlayerTransportRow(player: player)
            }
        }
    }
}

/// AVPlayerView with its native controls disabled — our `PlayerTransportRow`
/// is the only transport, so it can't fight the synced audio engine.
private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
