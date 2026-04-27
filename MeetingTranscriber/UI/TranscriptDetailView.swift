import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TranscriptDetailView: View {
    let documentID: String
    @Environment(AppState.self) private var appState

    @State private var renamingSpeakerID: Int? = nil
    @State private var newSpeakerNameDraft: String = ""
    @State private var titleDraft: String = ""
    @State private var justCopied: Bool = false
    @State private var summaryJustCopied: Bool = false
    @State private var audioPlayer = TranscriptAudioPlayer()
    @State private var showingCustomPromptPopover: Bool = false
    @State private var customSummaryPrompt: String = ""
    @State private var transcriptExpanded: Bool = false

    private var document: TranscriptDocument? {
        appState.transcripts.first(where: { $0.id == documentID })
    }

    var body: some View {
        if let doc = document {
            contentBody(for: doc)
                .onAppear {
                    titleDraft = doc.title
                    loadAudioIfAvailable(for: doc)
                }
                .onDisappear { audioPlayer.unload() }
        } else {
            ContentUnavailableView(
                "Transcript not found",
                systemImage: "text.magnifyingglass",
                description: Text("It may have been moved or deleted.")
            )
        }
    }

    private func loadAudioIfAvailable(for doc: TranscriptDocument) {
        if let voice = TranscriptStore.shared.audioURL(for: doc) {
            let system = TranscriptStore.shared.systemAudioURL(for: doc)
            audioPlayer.load(voiceURL: voice, systemURL: system)
        } else {
            audioPlayer.unload()
        }
    }

    @ViewBuilder
    private func contentBody(for doc: TranscriptDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBlock(for: doc)
                if audioPlayer.url != nil {
                    AudioPlayerCard(player: audioPlayer)
                }
                speakersBlock(for: doc)
                summaryBlock(for: doc)
                Divider()
                transcriptBlock(for: doc)
            }
            .padding(32)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            HStack(spacing: 10) {
                exportButton(for: doc)
                copyButton(for: doc)
            }
            .padding(24)
        }
    }

    // MARK: – Header
    @ViewBuilder
    private func headerBlock(for doc: TranscriptDocument) -> some View {
        HStack(alignment: .top) {
            headerTextBlock(for: doc)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                summarizeButton(for: doc)
                retranscribeButton(for: doc)
            }
        }
    }

    @ViewBuilder
    private func headerTextBlock(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $titleDraft)
                .font(Theme.titleFont)
                .textFieldStyle(.plain)
                .onSubmit {
                    appState.renameTranscript(id: documentID, to: titleDraft)
                }

            HStack(spacing: 8) {
                Label(doc.date.formatted(date: .abbreviated, time: .shortened),
                      systemImage: "calendar")
                Text("·")
                Label(formatDuration(doc.duration), systemImage: "clock")
                Text("·")
                Text("\(doc.language.flag) \(doc.language.displayName)")
                Text("·")
                Text(doc.modelShortName)
                if let src = doc.sourceURL, !src.isEmpty {
                    Text("·")
                    if doc.sourceKind == .imported {
                        Label(src, systemImage: "tray.and.arrow.down")
                            .lineLimit(1)
                    } else if let u = URL(string: src) {
                        Link(destination: u) {
                            Label(u.host ?? src, systemImage: "link")
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: – Speakers
    @ViewBuilder
    private func speakersBlock(for doc: TranscriptDocument) -> some View {
        if !doc.speakers.isEmpty {
            HStack(spacing: 8) {
                ForEach(doc.speakers) { sp in
                    speakerChip(sp)
                }
                Spacer()
            }
        }
    }

    private func speakerChip(_ sp: SpeakerLabel) -> some View {
        Button {
            renamingSpeakerID = sp.id
            newSpeakerNameDraft = sp.name
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(speakerTint(for: sp.id))
                    .frame(width: 8, height: 8)
                Text(sp.name)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .popover(isPresented: Binding(
            get: { renamingSpeakerID == sp.id },
            set: { if !$0, renamingSpeakerID == sp.id { renamingSpeakerID = nil } }
        )) {
            renamePopover(for: sp)
        }
    }

    @ViewBuilder
    private func renamePopover(for sp: SpeakerLabel) -> some View {
        VStack(spacing: 10) {
            TextField("Name", text: $newSpeakerNameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { commitSpeakerRename(id: sp.id) }
            HStack {
                Button("Cancel") { renamingSpeakerID = nil }
                Spacer()
                Button("Save") { commitSpeakerRename(id: sp.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func commitSpeakerRename(id: Int) {
        appState.renameSpeaker(transcriptID: documentID,
                               speakerID: id,
                               to: newSpeakerNameDraft)
        renamingSpeakerID = nil
    }

    // MARK: – Summarize button

    private var isSummarizingThis: Bool {
        appState.summarizingTranscriptID == documentID && appState.summarizationStage.isActive
    }

    @ViewBuilder
    private func summarizeButton(for doc: TranscriptDocument) -> some View {
        let hasSummary = (doc.summary?.isEmpty == false) || (doc.actionItems?.isEmpty == false)
        if isSummarizingThis {
            Button(role: .destructive) {
                appState.cancelSummarization()
            } label: {
                Label("Cancel", systemImage: "stop.circle")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        } else {
            HStack(spacing: 8) {
                Button {
                    appState.summarize(transcriptID: documentID)
                } label: {
                    Label(hasSummary ? "Regenerate" : "Summarize",
                          systemImage: "sparkles")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .help("Generate a local LLM summary for this transcript")

                Button {
                    showingCustomPromptPopover = true
                } label: {
                    Image(systemName: "text.bubble")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Summarize with a one-off custom prompt")
                .popover(isPresented: $showingCustomPromptPopover, arrowEdge: .top) {
                    customPromptPopover()
                }
            }
        }
    }

    // MARK: – Re-transcribe

    /// Currently running re-transcription job for this document, if any —
    /// lets the button flip into a progress state.
    private var activeRetranscribeJob: AppState.ProcessingJob? {
        appState.processingJobs.first(where: { $0.replacingDocumentID == documentID })
    }

    /// The Whisper model we'd upgrade to. Only offer a re-run when the
    /// existing transcript used Turbo — there's no point downgrading to a
    /// smaller model.
    private func retranscribeTarget(for doc: TranscriptDocument) -> WhisperModel? {
        doc.modelShortName == WhisperModel.largeV3Turbo.shortName ? .largeV3 : nil
    }

    @ViewBuilder
    private func retranscribeButton(for doc: TranscriptDocument) -> some View {
        if let target = retranscribeTarget(for: doc) {
            if let job = activeRetranscribeJob {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(retranscribeProgressLabel(for: job))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if TranscriptStore.shared.audioURL(for: doc) != nil {
                Button {
                    appState.retranscribe(documentID: documentID, with: target)
                } label: {
                    Label("Re-transcribe with \(target.shortName)",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Run transcription again with a larger model. Replaces segments and speakers; clears the summary.")
            }
        }
    }

    private func retranscribeProgressLabel(for job: AppState.ProcessingJob) -> String {
        switch job.stage {
        case .queued:                         return "Queued for re-transcription"
        case .running(let p, let stage):      return "\(stage) · \(Int(p * 100))%"
        case .failed(let msg):                return "Failed: \(msg)"
        }
    }

    @ViewBuilder
    private func customPromptPopover() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom summary prompt")
                .font(.headline)
            Text("Replaces only the summary instruction for this run. Action items, title, and the Settings system prompt still apply as usual.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $customSummaryPrompt)
                .font(.body)
                .frame(width: 420, height: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.15))
                )

            HStack {
                Button("Load default") {
                    if let doc = document {
                        customSummaryPrompt = SummaryPrompts.summaryInstruction(for: doc.language)
                    }
                }
                .controlSize(.small)
                Spacer()
                Button("Cancel") { showingCustomPromptPopover = false }
                    .keyboardShortcut(.cancelAction)
                Button("Summarize") {
                    showingCustomPromptPopover = false
                    appState.summarize(
                        transcriptID: documentID,
                        customSummaryInstruction: customSummaryPrompt
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(customSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }

    // MARK: – Summary block (streaming + saved)

    @ViewBuilder
    private func summaryBlock(for doc: TranscriptDocument) -> some View {
        if isSummarizingThis {
            liveStreamingBlock()
        } else if doc.summary != nil || (doc.actionItems?.isEmpty == false) {
            savedSummaryBlock(for: doc)
        } else if case .error(let msg) = appState.summarizationStage,
                  appState.summarizingTranscriptID == documentID {
            summaryErrorBlock(msg)
        }
    }

    @ViewBuilder
    private func liveStreamingBlock() -> some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                switch appState.summarizationStage {
                case .loadingModel(let fraction):
                    Label("Loading model…", systemImage: "arrow.down.circle")
                        .font(.headline)
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)

                case .generatingSummary(let text):
                    Label("Summary", systemImage: "sparkles")
                        .font(.headline)
                    streamingText(text, placeholder: "Generating…")

                case .generatingActions(let summary, let text):
                    Label("Summary", systemImage: "sparkles")
                        .font(.headline)
                    Text(summary).textSelection(.enabled)
                    Divider()
                    Label("Action items", systemImage: "checklist")
                        .font(.headline)
                    streamingText(text, placeholder: "Extracting…")

                case .generatingTitle(let summary, let actions):
                    Label("Summary", systemImage: "sparkles")
                        .font(.headline)
                    Text(summary).textSelection(.enabled)
                    if !actions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider()
                        Label("Action items", systemImage: "checklist")
                            .font(.headline)
                        Text(actions).textSelection(.enabled)
                    }
                    Divider()
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Titling…").foregroundStyle(.secondary)
                    }

                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func streamingText(_ text: String, placeholder: String) -> some View {
        if text.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(placeholder).foregroundStyle(.secondary)
            }
        } else {
            Text(text).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func savedSummaryBlock(for doc: TranscriptDocument) -> some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if doc.summary?.isEmpty == false {
                        Label("Summary", systemImage: "sparkles")
                            .font(.headline)
                    }
                    Spacer()
                    Button {
                        copySummaryMarkdown(doc)
                    } label: {
                        Label(summaryJustCopied ? "Copied!" : "Copy summary",
                              systemImage: summaryJustCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .sensoryFeedback(.success, trigger: summaryJustCopied) { _, new in new }
                    .help("Copy summary + action items as Markdown")
                }

                if let summary = doc.summary, !summary.isEmpty {
                    Text(summary).textSelection(.enabled)
                }
                if let actions = doc.actionItems, !actions.isEmpty {
                    Divider()
                    Label("Action items", systemImage: "checklist")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "circle")
                                    .foregroundStyle(.tertiary)
                                    .imageScale(.small)
                                Text(item).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let model = doc.summaryModelShortName,
                   let when = doc.summaryGeneratedAt {
                    Text("\(model) · \(when.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func copySummaryMarkdown(_ doc: TranscriptDocument) {
        guard let md = TranscriptFormatter.renderSummaryMarkdown(doc) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
        withAnimation(.snappy) { summaryJustCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.snappy) { summaryJustCopied = false }
        }
    }

    @ViewBuilder
    private func summaryErrorBlock(_ msg: String) -> some View {
        GlassCard(padding: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summarization failed").font(.headline)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }


    // MARK: – Transcript
    @ViewBuilder
    private func transcriptBlock(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                transcriptExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                        .rotationEffect(.degrees(transcriptExpanded ? 90 : 0))
                        .animation(.snappy(duration: 0.18), value: transcriptExpanded)
                    Text("Transcript").font(.headline)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(doc.segments.count) segment\(doc.segments.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                // Pad first, then set content shape so the hit area covers the
                // padding — the old 13 pt strip was the root of the "click the
                // chevron precisely" complaint.
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(transcriptExpanded ? "Hide transcript" : "Show transcript")
            .accessibilityAddTraits(.isHeader)

            if transcriptExpanded {
                transcriptSegments(for: doc)
            }
        }
    }

    @ViewBuilder
    private func transcriptSegments(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(doc.segments) { seg in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Button {
                        if audioPlayer.url != nil {
                            audioPlayer.seek(to: seg.start)
                            if !audioPlayer.isPlaying { audioPlayer.togglePlay() }
                        }
                    } label: {
                        Text(formatTimestamp(seg.start))
                            .font(Theme.monoFont)
                            .monospacedDigit()
                            .foregroundStyle(audioPlayer.url != nil
                                             ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.tertiary))
                            .frame(width: 72, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(audioPlayer.url == nil)
                    .help(audioPlayer.url != nil ? "Play from here" : "")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(speakerName(for: seg.speakerId, in: doc))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(speakerTint(for: seg.speakerId))
                        Text(seg.text)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: – Copy button (floating)
    private func copyButton(for doc: TranscriptDocument) -> some View {
        Button {
            copyMarkdown(doc)
        } label: {
            Label(justCopied ? "Copied!" : "Copy as Markdown",
                  systemImage: justCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                .padding(.horizontal, 8)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(justCopied ? .green : .accentColor)
        .sensoryFeedback(.success, trigger: justCopied) { _, new in new }
        .keyboardShortcut("c", modifiers: [.command, .shift])
    }

    private func copyMarkdown(_ doc: TranscriptDocument) {
        let md = TranscriptFormatter.renderMarkdown(doc)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
        withAnimation(.snappy) { justCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            withAnimation(.snappy) { justCopied = false }
        }
    }

    // MARK: – Export button (save .md to disk)
    private func exportButton(for doc: TranscriptDocument) -> some View {
        Button {
            exportMarkdown(doc)
        } label: {
            Label("Save as .md…", systemImage: "square.and.arrow.down.fill")
                .padding(.horizontal, 8)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(.accentColor)
        .keyboardShortcut("e", modifiers: [.command, .shift])
    }

    private func exportMarkdown(_ doc: TranscriptDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.sanitizeFilename(doc.title) + ".md"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let md = TranscriptFormatter.renderMarkdown(doc)
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appState.lastError = "Could not save Markdown: \(error.localizedDescription)"
        }
    }

    /// Strip characters that confuse the filesystem so doc.title can be used
    /// as a default filename. Falls back to "Transcript" for an empty result.
    private static func sanitizeFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.isEmpty ? "Transcript" : cleaned
    }

    // MARK: – Helpers
    private func speakerName(for id: Int, in doc: TranscriptDocument) -> String {
        doc.speakers.first(where: { $0.id == id })?.name ?? "Unknown"
    }

    private func speakerTint(for id: Int) -> Color {
        let palette: [Color] = [.blue, .orange, .purple, .green, .pink, .teal]
        if id < 0 { return .gray }
        return palette[id % palette.count]
    }

    private func formatTimestamp(_ s: Double) -> String {
        let t = Int(s)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatDuration(_ s: TimeInterval) -> String { formatTimestamp(s) }
}
