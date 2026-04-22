import SwiftUI

/// The visible element in the macOS menu bar.
struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        switch state.recordingState {
        case .idle:
            if state.isProcessing {
                Image(systemName: "gear.badge")
            } else {
                Image(systemName: "waveform.circle")
            }
        case .preparing:
            Image(systemName: "circle.dotted")
        case .recording:
            Label {
                Text(formatElapsed(state.elapsedSeconds))
                    .monospacedDigit()
            } icon: {
                Image(systemName: state.isMicMuted ? "mic.slash.fill" : "record.circle.fill")
                    .foregroundStyle(.red)
            }
        case .stopping:
            Image(systemName: "stop.circle")
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
