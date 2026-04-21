import SwiftUI

struct TranscriptListRow: View {
    let doc: TranscriptDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(doc.title)
                .font(.headline)
                .lineLimit(1)

            if let preview = previewText, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 6) {
                Text(doc.date, style: .date)
                Text("·")
                Text(formatDuration(doc.duration))
                Text("·")
                Text(doc.language.flag)
                if doc.sourceKind == .imported {
                    Text("·")
                    Image(systemName: "tray.and.arrow.down").imageScale(.small)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private var previewText: String? {
        let joined = doc.segments.prefix(4).map(\.text).joined(separator: " ")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > 180 {
            return String(trimmed.prefix(180)) + "…"
        }
        return trimmed
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}
