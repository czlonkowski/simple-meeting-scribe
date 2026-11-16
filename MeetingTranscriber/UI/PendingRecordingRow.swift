import SwiftUI

/// Sidebar row for a recording on disk that has no transcript yet.
struct PendingRecordingRow: View {
    let pending: PendingRecording
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text(pending.title)
                .font(.headline)
                .lineLimit(1)

            statusLabel
                .font(.caption)
                .lineLimit(2)

            HStack(spacing: Theme.space3) {
                Text(pending.startedAt, style: .date)
                Text("·")
                Text(pending.startedAt, style: .time)
                Text("·")
                Text(PendingRecordingRow.formatDuration(pending.estimatedDuration))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusLabel: some View {
        if appState.recoveryJob(for: pending) != nil {
            Label("Transcribing…", systemImage: "waveform")
                .foregroundStyle(.secondary)
        } else if let error = pending.sidecar?.lastError {
            Label("Transcription failed: \(error)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Label("Not transcribed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    static func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}
