import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TranscriptDetailView: View {
    let documentID: String
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var renamingSpeakerID: Int? = nil
    @State private var newSpeakerNameDraft: String = ""
    @State private var showingAddTagPopover: Bool = false
    @State private var tagNameDraft: String = ""
    @State private var titleDraft: String = ""
    @State private var justCopied: Bool = false
    @State private var summaryJustCopied: Bool = false
    @State private var audioPlayer = TranscriptAudioPlayer()
    @State private var showingCustomPromptPopover: Bool = false
    @State private var customSummaryPrompt: String = ""
    @State private var transcriptExpanded: Bool = false
    @State private var showDateEditor: Bool = false
    @State private var recordedDraft: Date = Date()
    /// Per-summary glossary toggle. Defaults to true whenever any glossary
    /// entry is enabled; resets on each detail-view appearance.
    @State private var useGlossaryThisRun: Bool = true
    /// Per-summary "identify speakers" toggle. Defaults to true when at least
    /// one default-named ("Remote", "Remote N") speaker still exists.
    @State private var inferSpeakerNamesThisRun: Bool = true

    private var document: TranscriptDocument? {
        appState.transcripts.first(where: { $0.id == documentID })
    }

    private var entranceAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .snappy(duration: 0.22)
    }

    private var summaryCardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.97).combined(with: .opacity)
    }

    private var bottomRevealTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .bottom))
    }

    var body: some View {
        if let doc = document {
            contentBody(for: doc)
                .onAppear {
                    titleDraft = doc.title
                    loadAudioIfAvailable(for: doc)
                    useGlossaryThisRun = appState.glossaryTerms.contains(where: \.isEnabled)
                    inferSpeakerNamesThisRun = doc.speakers.contains { Self.hasDefaultRemoteName($0.name) }
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
            if let video = TranscriptStore.shared.videoURL(for: doc) {
                audioPlayer.attachVideo(url: video, offset: doc.videoStartOffset ?? 0)
            }
        } else {
            audioPlayer.unload()
        }
    }

    @ViewBuilder
    private func contentBody(for doc: TranscriptDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBlock(for: doc)
                if audioPlayer.videoURL != nil {
                    VideoPlayerCard(player: audioPlayer)
                } else if audioPlayer.url != nil {
                    AudioPlayerCard(player: audioPlayer)
                }
                speakersBlock(for: doc)
                tagsBlock(for: doc)
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
            .padding(Theme.space12)
        }
    }

    // MARK: – Header
    @ViewBuilder
    private func headerBlock(for doc: TranscriptDocument) -> some View {
        HStack(alignment: .top) {
            headerTextBlock(for: doc)
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.space3) {
                summarizeButton(for: doc)
                retranscribeButton(for: doc)
            }
        }
    }

    @ViewBuilder
    private func headerTextBlock(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            TextField("Title", text: $titleDraft)
                .font(Theme.titleFont)
                .tracking(-0.4)
                .textFieldStyle(.plain)
                .onSubmit {
                    appState.renameTranscript(id: documentID, to: titleDraft)
                }

            HStack(spacing: Theme.space4) {
                Button {
                    recordedDraft = doc.displayDate
                    showDateEditor = true
                } label: {
                    Label(dateLabelText(for: doc), systemImage: "calendar")
                }
                .buttonStyle(.pressable)
                .help(doc.recordedAt != nil
                      ? "Recorded \(doc.displayDate.formatted(date: .abbreviated, time: .omitted)) · transcribed \(doc.date.formatted(date: .abbreviated, time: .shortened)). Click to edit."
                      : "Transcribed \(doc.date.formatted(date: .abbreviated, time: .shortened)). Click to set the recording date.")
                .popover(isPresented: $showDateEditor, arrowEdge: .bottom) {
                    dateEditorPopover(for: doc)
                }
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

    /// Recording date shows date-only (it's day-level); the transcription-date
    /// fallback keeps its time, which is meaningful.
    private func dateLabelText(for doc: TranscriptDocument) -> String {
        doc.recordedAt != nil
            ? doc.displayDate.formatted(date: .abbreviated, time: .omitted)
            : doc.displayDate.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private func dateEditorPopover(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.space6) {
            Text("Recording date")
                .font(.headline)
            DatePicker("", selection: $recordedDraft, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if doc.recordedAt != nil {
                    Button("Clear") {
                        appState.setRecordedAt(nil, for: documentID)
                        showDateEditor = false
                    }
                }
                Spacer()
                Button("Set") {
                    appState.setRecordedAt(recordedDraft, for: documentID)
                    showDateEditor = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }

    // MARK: – Speakers
    @ViewBuilder
    private func speakersBlock(for doc: TranscriptDocument) -> some View {
        if !doc.speakers.isEmpty {
            HStack(spacing: Theme.space4) {
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
            HStack(spacing: Theme.space3) {
                Circle()
                    .fill(speakerTint(for: sp.id))
                    .frame(width: 8, height: 8)
                Text(sp.name)
            }
            .padding(.horizontal, Theme.space6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .chipHover()
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
        .padding(Theme.space6)
    }

    private func commitSpeakerRename(id: Int) {
        appState.renameSpeaker(transcriptID: documentID,
                               speakerID: id,
                               to: newSpeakerNameDraft)
        renamingSpeakerID = nil
    }

    // MARK: – Tags
    @ViewBuilder
    private func tagsBlock(for doc: TranscriptDocument) -> some View {
        HStack(spacing: Theme.space4) {
            ForEach(doc.tags, id: \.self) { tagName in
                assignedTagChip(tagName)
            }

            Button {
                tagNameDraft = ""
                showingAddTagPopover = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .chipHover()
            .help("Add tag")
            .popover(isPresented: $showingAddTagPopover, arrowEdge: .bottom) {
                addTagPopover()
            }

            Spacer()
        }
    }

    private func assignedTagChip(_ tagName: String) -> some View {
        Button {
            removeTag(tagName)
        } label: {
            HStack(spacing: Theme.space3) {
                Circle()
                    .fill(appState.color(for: tagName).swiftUIColor)
                    .frame(width: 8, height: 8)
                Text(tagName)
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.space6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .chipHover()
        .help("Remove \(tagName)")
    }

    @ViewBuilder
    private func addTagPopover() -> some View {
        let suggestions = tagSuggestions()
        let canCreate = canCreateDraftTag()
        VStack(alignment: .leading, spacing: 10) {
            Text("Add tag")
                .font(.headline)
            TextField("Tag name", text: $tagNameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { commitTagDraft() }

            if !suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.space2) {
                        ForEach(suggestions) { tag in
                            Button {
                                addTag(tag.name)
                            } label: {
                                HStack(spacing: Theme.space4) {
                                    Circle()
                                        .fill(tag.color.swiftUIColor)
                                        .frame(width: 8, height: 8)
                                    Text(tag.name)
                                    Spacer()
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.pressable)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            if canCreate {
                Button {
                    commitTagDraft()
                } label: {
                    HStack(spacing: Theme.space4) {
                        Circle()
                            .fill(nextAutoTagColor.swiftUIColor)
                            .frame(width: 8, height: 8)
                        Text("Create “\(trimmedTagDraft)”")
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable)
            }

            HStack {
                Spacer()
                Button("Done") {
                    showingAddTagPopover = false
                    tagNameDraft = ""
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.space6)
    }

    private var trimmedTagDraft: String {
        TagStore.cleanName(tagNameDraft)
    }

    private var nextAutoTagColor: TagColor {
        TagColor.allCases[appState.tagCatalog.count % TagColor.allCases.count]
    }

    /// Tags currently assigned to this transcript, read live from the store by
    /// the stable `documentID`. Never use a captured `doc` snapshot here: the
    /// add-tag popover holds its `doc` from presentation time, so a snapshot
    /// goes stale and makes `setTags` operate on outdated tags.
    private var currentTags: [String] {
        document?.tags ?? []
    }

    private func tagSuggestions() -> [Tag] {
        let assignedKeys = Set(currentTags.map { TagStore.key(for: $0) })
        let query = TagStore.key(for: tagNameDraft)
        return appState.tagCatalog.filter { tag in
            let key = TagStore.key(for: tag.name)
            guard !assignedKeys.contains(key) else { return false }
            return query.isEmpty || key.contains(query)
        }
    }

    private func canCreateDraftTag() -> Bool {
        let name = trimmedTagDraft
        let key = TagStore.key(for: name)
        guard !name.isEmpty,
              !currentTags.contains(where: { TagStore.key(for: $0) == key })
        else { return false }
        return !appState.tagCatalog.contains(where: { TagStore.key(for: $0.name) == key })
    }

    private func commitTagDraft() {
        let name = trimmedTagDraft
        guard !name.isEmpty else { return }
        addTag(name)
    }

    private func addTag(_ name: String) {
        appState.setTags(currentTags + [name], for: documentID)
        tagNameDraft = ""
        showingAddTagPopover = false
    }

    private func removeTag(_ name: String) {
        let key = TagStore.key(for: name)
        appState.setTags(currentTags.filter { TagStore.key(for: $0) != key }, for: documentID)
    }

    // MARK: – Summarize button

    private var isSummarizingThis: Bool {
        appState.summarizingTranscriptID == documentID && appState.summarizationStage.isActive
    }

    private var currentSummaryErrorMessage: String? {
        guard case .error(let msg) = appState.summarizationStage,
              appState.summarizingTranscriptID == documentID
        else { return nil }
        return msg
    }

    @ViewBuilder
    private func summarizeButton(for doc: TranscriptDocument) -> some View {
        let hasSummary = (doc.summary?.isEmpty == false)
        if isSummarizingThis {
            Button(role: .destructive) {
                appState.cancelSummarization()
            } label: {
                Label("Cancel", systemImage: "stop.circle")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        } else {
            VStack(alignment: .trailing, spacing: Theme.space3) {
                HStack(spacing: Theme.space4) {
                    Button {
                        appState.summarize(transcriptID: documentID,
                                           useGlossary: useGlossaryThisRun,
                                           inferSpeakerNames: inferSpeakerNamesThisRun)
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
                summaryOptionsRow(for: doc)
            }
        }
    }

    /// Three peer chips beneath the Summarize button — model, glossary,
    /// identify-speakers. Same caption styling for visual unity; on/off toggles
    /// signal state via filled vs outline SF Symbols.
    @ViewBuilder
    private func summaryOptionsRow(for doc: TranscriptDocument) -> some View {
        HStack(spacing: 14) {
            summaryModelMenu(for: doc)
            glossaryChip()
            identifyChip(for: doc)
        }
    }

    /// Per-meeting LLM picker. Defaults to the Settings model for the
    /// transcript's language; selecting a non-default model persists the choice
    /// on the document. Both the summary pass and the title pass use it.
    @ViewBuilder
    private func summaryModelMenu(for doc: TranscriptDocument) -> some View {
        let language = doc.language
        let langDefault: LanguageModel = (language == .polish)
            ? appState.defaultModelPolish
            : appState.defaultModelEnglish
        let effective = doc.summaryModelOverride ?? langDefault
        // Per-meeting override is explicit user intent — list every model.
        // The Settings defaults are still filtered by supportedLanguages.
        let allModels = LanguageModel.allCases

        Menu {
            ForEach(allModels) { m in
                Button {
                    appState.setSummaryModelOverride(
                        m == langDefault ? nil : m,
                        for: documentID
                    )
                } label: {
                    HStack {
                        if m == effective {
                            Image(systemName: "checkmark")
                        }
                        Text(m.displayName)
                        if !appState.downloadedModelIDs.contains(m.repoID) {
                            Text("· downloads on first use")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if doc.summaryModelOverride != nil {
                Divider()
                Button("Reset to Settings default") {
                    appState.setSummaryModelOverride(nil, for: documentID)
                }
            }
        } label: {
            Label(effective.shortName, systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .chipHover()
        .help("Choose the LLM used for the summary and title. Defaults to the Settings model for this language.")
    }

    /// Per-summary opt-in for the glossary appendix. Hidden when no glossary
    /// entries are enabled — nothing to toggle.
    @ViewBuilder
    private func glossaryChip() -> some View {
        if appState.glossaryTerms.contains(where: \.isEnabled) {
            optionChip(
                title: "Glossary",
                isOn: useGlossaryThisRun,
                onSymbol: "book.closed.fill",
                offSymbol: "book.closed",
                help: useGlossaryThisRun
                    ? "Disable the glossary for this run."
                    : "Inject the Settings glossary so the LLM understands domain terms."
            ) {
                useGlossaryThisRun.toggle()
            }
        }
    }

    /// Per-summary opt-in for the speaker-identification LLM pass. Hidden when
    /// every speaker already has a non-default name (user-edited, or already
    /// inferred from a previous summarization).
    @ViewBuilder
    private func identifyChip(for doc: TranscriptDocument) -> some View {
        if doc.speakers.contains(where: { Self.hasDefaultRemoteName($0.name) }) {
            optionChip(
                title: "Identify",
                isOn: inferSpeakerNamesThisRun,
                onSymbol: "person.text.rectangle.fill",
                offSymbol: "person.text.rectangle",
                help: inferSpeakerNamesThisRun
                    ? "Skip the speaker-identification pass for this run."
                    : "Run a quick LLM pass to infer names of placeholder \"Remote\" speakers."
            ) {
                inferSpeakerNamesThisRun.toggle()
            }
        }
    }

    /// Common visual treatment for the two boolean chips. Mirrors the model
    /// chip (caption font, secondary tint, leading SF Symbol). Active state
    /// uses the filled symbol variant and a slightly stronger tint.
    private func optionChip(
        title: String,
        isOn: Bool,
        onSymbol: String,
        offSymbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: isOn ? onSymbol : offSymbol)
                .font(.caption)
                .foregroundStyle(isOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.pressable)
        .fixedSize()
        .chipHover()
        .help(help)
    }

    /// True for the generator-assigned defaults `"Remote"` and `"Remote N"`.
    /// User-edited names never match.
    private static func hasDefaultRemoteName(_ name: String) -> Bool {
        if name == "Remote" { return true }
        guard name.hasPrefix("Remote "), name.count > 7 else { return false }
        return name.dropFirst(7).allSatisfy(\.isNumber)
    }

    // MARK: – Re-transcribe

    /// Currently running re-transcription job for this document, if any —
    /// lets the button flip into a progress state.
    private var activeRetranscribeJob: AppState.ProcessingJob? {
        appState.processingJobs.first(where: { $0.replacingDocumentID == documentID })
    }

    /// Every model except the one this transcript was made with — re-running
    /// with the same model would just reproduce the result.
    private func retranscribeTargets(for doc: TranscriptDocument) -> [WhisperModel] {
        WhisperModel.allCases.filter { $0.shortName != doc.modelShortName }
    }

    @ViewBuilder
    private func retranscribeButton(for doc: TranscriptDocument) -> some View {
        if let job = activeRetranscribeJob {
            HStack(spacing: Theme.space3) {
                ProgressView().controlSize(.small)
                Text(retranscribeProgressLabel(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if TranscriptStore.shared.audioURL(for: doc) != nil {
            Menu {
                ForEach(retranscribeTargets(for: doc)) { target in
                    Button(target.isCloud ? "with ElevenLabs Scribe v2 (cloud)"
                                          : "with Whisper \(target.shortName)") {
                        appState.retranscribe(documentID: documentID, with: target)
                    }
                }
            } label: {
                Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Run transcription again with a different model. Replaces segments and speakers; clears the summary.")
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
            Text("Replaces only the summary instruction for this run. Title and the Settings system prompt still apply as usual.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $customSummaryPrompt)
                .font(.body)
                .frame(width: 420, height: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
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
                        customSummaryInstruction: customSummaryPrompt,
                        useGlossary: useGlossaryThisRun,
                        inferSpeakerNames: inferSpeakerNamesThisRun
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
        let summaryErrorMessage = currentSummaryErrorMessage

        Group {
            if isSummarizingThis {
                liveStreamingBlock()
                    .transition(summaryCardTransition)
            } else if doc.summary?.isEmpty == false {
                savedSummaryBlock(for: doc)
            } else if let msg = summaryErrorMessage {
                summaryErrorBlock(msg)
                    .transition(summaryCardTransition)
            }
        }
        .animation(entranceAnimation, value: isSummarizingThis)
        .animation(entranceAnimation, value: summaryErrorMessage != nil)
    }

    @ViewBuilder
    private func liveStreamingBlock() -> some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: Theme.space6) {
                switch appState.summarizationStage {
                case .loadingModel(let fraction):
                    Label("Loading model…", systemImage: "arrow.down.circle")
                        .font(.headline)
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)

                case .identifyingSpeakers:
                    Label("Identifying speakers…", systemImage: "person.text.rectangle")
                        .font(.headline)
                    HStack(spacing: Theme.space4) {
                        ProgressView().controlSize(.small)
                        Text("Reading transcript…").foregroundStyle(.secondary)
                    }

                case .generatingSummary(let text):
                    Label("Summary", systemImage: "sparkles")
                        .font(Theme.sectionTitleFont)
                    streamingText(text, placeholder: "Generating…")

                case .generatingTitle(let summary):
                    Label("Summary", systemImage: "sparkles")
                        .font(Theme.sectionTitleFont)
                    Text(markdown: summary).textSelection(.enabled)
                    Divider()
                    HStack(spacing: Theme.space4) {
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
            HStack(spacing: Theme.space4) {
                ProgressView().controlSize(.small)
                Text(placeholder).foregroundStyle(.secondary)
            }
        } else {
            Text(markdown: text).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func savedSummaryBlock(for doc: TranscriptDocument) -> some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: Theme.space6) {
                HStack {
                    if doc.summary?.isEmpty == false {
                        Label("Summary", systemImage: "sparkles")
                            .font(Theme.sectionTitleFont)
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
                    .help("Copy summary as Markdown")
                }

                if let summary = doc.summary, !summary.isEmpty {
                    Text(markdown: summary).textSelection(.enabled)
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
        GlassCard(padding: Theme.space8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: Theme.space2) {
                    Text("Summarization failed").font(.headline)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }


    // MARK: – Transcript
    @ViewBuilder
    private func transcriptBlock(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            Button {
                withAnimation(entranceAnimation) {
                    transcriptExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                        .rotationEffect(.degrees(transcriptExpanded ? 90 : 0))
                        .animation(.snappy(duration: 0.18), value: transcriptExpanded)
                    Text("Transcript").font(Theme.sectionTitleFont)
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
            .buttonStyle(.pressable)
            .accessibilityLabel(transcriptExpanded ? "Hide transcript" : "Show transcript")
            .accessibilityAddTraits(.isHeader)

            if transcriptExpanded {
                transcriptSegments(for: doc)
                    .transition(bottomRevealTransition)
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
                                             ? AnyShapeStyle(Theme.accent)
                                             : AnyShapeStyle(.tertiary))
                            .frame(width: 72, alignment: .leading)
                    }
                    .buttonStyle(.pressable)
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
                .padding(.horizontal, Theme.space4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(justCopied ? .green : Theme.accent)
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
                .padding(.horizontal, Theme.space4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(Theme.accent)
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
        if id < 0 { return .gray }
        return Theme.speakerColor(for: id)
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
