import SwiftUI
import AppKit

/// The live transcript on the Record tab: newest text at the bottom, kept in
/// view unless you scroll up to read, plus copy buttons for Claude.
struct LiveTranscriptPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var followsLatest = true
    @State private var copiedLabel: String?

    private static let recentWindow: TimeInterval = 5 * 60

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.space6) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var live: LiveTranscript { appState.liveTranscript }

    private var myName: String {
        LiveTranscriptFormat.displayName(for: appState.userDisplayName)
    }

    // MARK: – Header

    private var header: some View {
        HStack(spacing: Theme.space4) {
            Image(systemName: "captions.bubble")
                .foregroundStyle(.secondary)
            Text("Live transcript")
                .font(Theme.sectionTitleFont)
            statusLabel
            Spacer()
            if let copiedLabel {
                Text(copiedLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Button("Last 5 min", systemImage: "doc.on.doc") {
                copy(LiveTranscriptFormat.recent(live.segments, seconds: Self.recentWindow),
                     label: "Copied last 5 min")
            }
            .help("Copy the last 5 minutes as Markdown")
            .disabled(live.segments.isEmpty)
            Button("Copy all", systemImage: "doc.on.clipboard") {
                copy(live.segments, label: "Copied")
            }
            .help("Copy the whole live transcript as Markdown")
            .disabled(live.segments.isEmpty)
            if live.status == .off || isFailed {
                Button("Clear", systemImage: "xmark") {
                    live.clear()
                }
                .labelStyle(.iconOnly)
                .help("Hide the live transcript of the last recording")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch live.status {
        case .loading:
            HStack(spacing: Theme.space3) {
                ProgressView().controlSize(.mini)
                Text("Loading model…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .running:
            Text(runningLabel)
                .font(.caption)
                .foregroundStyle(live.engine == .onDeviceFallback ? Color.orange : .secondary)
                .help(live.engine == .onDeviceFallback
                      ? "Azure Speech failed, so this Mac transcribes the rest of the recording."
                      : "A draft. The usual transcript replaces it when you stop.")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .off:
            if !live.segments.isEmpty {
                Text("Last recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runningLabel: String {
        switch live.engine {
        case .azure: return "Azure Speech · about 1 s behind"
        case .onDeviceFallback: return "On this Mac (Azure failed) · about 15 s behind"
        case .onDevice, nil: return "On this Mac · about 15 s behind"
        }
    }

    private var isFailed: Bool {
        if case .failed = live.status { return true }
        return false
    }

    // MARK: – Text

    @ViewBuilder
    private var content: some View {
        let turns = LiveTranscriptFormat.turns(live.segments)
        let partials = [LiveSpeaker.me, .others].compactMap { speaker in
            live.partial[speaker].map { (speaker, $0) }
        }
        if turns.isEmpty && partials.isEmpty {
            Text(live.status == .running || live.status == .loading
                 ? (live.engine == .azure
                    ? "Text appears here at the end of each sentence."
                    : "Text appears here about 15 seconds after it is said.")
                 : "No live text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.space6) {
                    ForEach(turns) { turn in
                        LiveTurnRow(turn: turn, myName: myName)
                    }
                    ForEach(partials, id: \.0) { speaker, text in
                        LivePartialRow(name: speaker == .me ? myName : "Others", speaker: speaker, text: text)
                    }
                }
                .padding(.trailing, Theme.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                followsLatest = atBottom
            }
            .onChange(of: scrollTrigger) {
                guard followsLatest else { return }
                if reduceMotion {
                    scrollPosition.scrollTo(edge: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) }
                }
            }
        }
    }

    /// Changes whenever new final or interim text arrives.
    private var scrollTrigger: String {
        "\(live.cursor)|\(live.partial[.me]?.count ?? 0)|\(live.partial[.others]?.count ?? 0)"
    }

    private func copy(_ segments: [LiveSegment], label: String) {
        let markdown = LiveTranscriptFormat.markdown(segments, myName: myName)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copiedLabel = label }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                if copiedLabel == label { copiedLabel = nil }
            }
        }
    }
}

private struct LiveTurnRow: View {
    let turn: LiveTurn
    let myName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack(spacing: Theme.space4) {
                Text(turn.speaker == .me ? myName : "Others")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(turn.speaker == .me ? Theme.speakerColor(for: 0) : Theme.speakerColor(for: 1))
                Text(LiveTranscriptFormat.timestamp(turn.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(turn.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The sentence being heard right now. Greyed out because it may change.
private struct LivePartialRow: View {
    let name: String
    let speaker: LiveSpeaker
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(speaker == .me ? Theme.speakerColor(for: 0) : Theme.speakerColor(for: 1))
                .opacity(0.6)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("\(name), still speaking: \(text)")
    }
}
