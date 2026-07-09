import SwiftUI

struct TranscriptListRow: View {
    let doc: TranscriptDocument
    @Environment(AppState.self) private var appState

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
                Text(doc.displayDate, style: .date)
                Text("·")
                Text(formatDuration(doc.duration))
                Text("·")
                Text(doc.language.flag)
                if doc.sourceKind == .imported {
                    Text("·")
                    Image(systemName: "tray.and.arrow.down").imageScale(.small)
                }
                if !doc.tags.isEmpty {
                    Text("·")
                    ForEach(Array(doc.tags.prefix(3)), id: \.self) { tagName in
                        CompactTagChip(
                            name: tagName,
                            color: appState.color(for: tagName).swiftUIColor
                        )
                    }
                    if doc.tags.count > 3 {
                        Text("+\(doc.tags.count - 3)")
                    }
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

private struct CompactTagChip: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 72, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(color.opacity(0.28), lineWidth: 0.5)
        }
    }
}
