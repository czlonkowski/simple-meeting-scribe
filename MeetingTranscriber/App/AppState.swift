import Foundation
import Observation
import SwiftUI
import AppKit

@MainActor
@Observable
final class AppState {
    // MARK: – Settings
    var selectedModel: WhisperModel = .largeV3Turbo
    var defaultLanguage: TranscriptionLanguage = .english
    var captureSystemAudio: Bool = true

    // MARK: – Dictionary (persisted via DictionaryStore)
    var languagePrimes: [String: String] = DictionaryStore.loadPrimes()
    var wordReplacements: [WordReplacement] = DictionaryStore.loadReplacements()

    func setPrime(_ text: String, for language: TranscriptionLanguage) {
        languagePrimes[language.rawValue] = text
        DictionaryStore.savePrimes(languagePrimes)
    }

    func addReplacement(_ entry: WordReplacement) {
        wordReplacements.append(entry)
        DictionaryStore.saveReplacements(wordReplacements)
    }

    func updateReplacement(_ entry: WordReplacement) {
        guard let idx = wordReplacements.firstIndex(where: { $0.id == entry.id }) else { return }
        wordReplacements[idx] = entry
        DictionaryStore.saveReplacements(wordReplacements)
    }

    func removeReplacements(withIDs ids: Set<UUID>) {
        wordReplacements.removeAll { ids.contains($0.id) }
        DictionaryStore.saveReplacements(wordReplacements)
    }

    // MARK: – Summarization settings (persisted via SummaryStore)
    var defaultModelEnglish: LanguageModel = SummaryStore.loadDefaultModel(for: .english)
    var defaultModelPolish:  LanguageModel = SummaryStore.loadDefaultModel(for: .polish)
    var systemPromptEnglish: String        = SummaryStore.loadSystemPrompt(for: .english)
    var systemPromptPolish:  String        = SummaryStore.loadSystemPrompt(for: .polish)
    var downloadedModelIDs:  Set<String>   = SummaryStore.loadDownloadedIDs()

    func setDefaultModel(_ model: LanguageModel, for language: TranscriptionLanguage) {
        switch language {
        case .english: defaultModelEnglish = model
        case .polish:  defaultModelPolish = model
        }
        SummaryStore.saveDefaultModel(model, for: language)
    }

    func setSystemPrompt(_ text: String, for language: TranscriptionLanguage) {
        switch language {
        case .english: systemPromptEnglish = text
        case .polish:  systemPromptPolish = text
        }
        SummaryStore.saveSystemPrompt(text, for: language)
    }

    // MARK: – Summarization runtime state
    enum ModelDownloadState: Equatable {
        case notDownloaded
        case downloading(fraction: Double)
        case downloaded
    }
    var modelDownloadStates: [LanguageModel: ModelDownloadState] = [:]
    private var downloadTasks: [LanguageModel: Task<Void, Error>] = [:]

    enum SummarizationStage: Equatable {
        case idle
        case loadingModel(fraction: Double)
        case generatingSummary(text: String)
        // Summary is finalized at this point — carried forward so the UI keeps
        // it visible while action items stream in.
        case generatingActions(summary: String, text: String)
        // Title pass after actions; both earlier results kept for display.
        case generatingTitle(summary: String, actions: String)
        case done
        case error(String)

        var isActive: Bool {
            switch self {
            case .idle, .done, .error: false
            default: true
            }
        }
    }
    var summarizationStage: SummarizationStage = .idle
    var summarizingTranscriptID: String?
    private let summaryEngine = SummarizationEngine()
    private var summarizeTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    /// How long to keep the summarization model resident after the last use
    /// before dropping it. Keeps consecutive summaries fast while releasing
    /// 4–8 GB of unified memory when you walk away.
    private let idleUnloadAfterSeconds: UInt64 = 180

    func modelState(for model: LanguageModel) -> ModelDownloadState {
        if let state = modelDownloadStates[model] { return state }
        return downloadedModelIDs.contains(model.repoID) ? .downloaded : .notDownloaded
    }

    // MARK: – Model library actions

    func downloadModel(_ model: LanguageModel) {
        guard downloadTasks[model] == nil else {
            NSLog("Summary: downloadModel(%@) ignored — already in flight", model.shortName)
            return
        }
        NSLog("Summary: downloadModel(%@) started", model.shortName)
        modelDownloadStates[model] = .downloading(fraction: 0)

        downloadTasks[model] = Task { [weak self, summaryEngine] in
            defer {
                Task { @MainActor in
                    self?.downloadTasks[model] = nil
                }
            }
            do {
                try await summaryEngine.prefetch(model) { fraction in
                    NSLog("Summary: %@ progress %.3f", model.shortName, fraction)
                    Task { @MainActor in
                        self?.modelDownloadStates[model] = .downloading(fraction: fraction)
                    }
                }
                NSLog("Summary: prefetch(%@) returned ok", model.shortName)
                await MainActor.run {
                    self?.markDownloaded(model)
                }
            } catch is CancellationError {
                NSLog("Summary: prefetch(%@) cancelled", model.shortName)
                await MainActor.run {
                    self?.modelDownloadStates[model] = .notDownloaded
                }
            } catch {
                NSLog("Summary: prefetch(%@) error: %@", model.shortName, String(describing: error))
                await MainActor.run {
                    self?.modelDownloadStates[model] = .notDownloaded
                    self?.lastError = "Model download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelDownload(_ model: LanguageModel) {
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil
        modelDownloadStates[model] = .notDownloaded
    }

    func deleteModel(_ model: LanguageModel) {
        // Cancel active task first.
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil

        // Best-effort delete from the common HuggingFace cache locations.
        SummaryStore.deleteCachedFiles(for: model)

        downloadedModelIDs.remove(model.repoID)
        SummaryStore.saveDownloadedIDs(downloadedModelIDs)
        modelDownloadStates[model] = .notDownloaded
    }

    func unloadSummaryModel() async {
        await summaryEngine.unload()
    }

    private func markDownloaded(_ model: LanguageModel) {
        NSLog("Summary: markDownloaded(%@)", model.shortName)
        downloadedModelIDs.insert(model.repoID)
        SummaryStore.saveDownloadedIDs(downloadedModelIDs)
        modelDownloadStates[model] = .downloaded
    }

    // MARK: – Summarize a transcript

    /// Summarize a transcript.
    ///
    /// `customSummaryInstruction`, if non-empty, replaces the built-in
    /// "write 3–6 sentences…" user prompt for *just the summary pass*. The
    /// action-items and title passes always use their defaults. This is the
    /// per-invocation override surfaced via the popover next to the
    /// Summarize/Regenerate button; the persistent system prompt in Settings
    /// is still applied on top as the `instructions:` for the ChatSession.
    func summarize(transcriptID: String, customSummaryInstruction: String? = nil) {
        guard let doc = transcripts.first(where: { $0.id == transcriptID }) else { return }
        guard summarizeTask == nil else { return }
        cancelIdleUnload()

        let language = doc.language
        let model = language == .polish ? defaultModelPolish : defaultModelEnglish
        let systemPrompt = language == .polish ? systemPromptPolish : systemPromptEnglish
        let feed = TranscriptFormatter.renderPlainForLLM(doc)
        let disableThinking = model.usesThinkingMode
        let currentTitle = doc.title
        // For imported files, sourceURL holds the original filename (see
        // `TranscriptionPipeline.importedFileName`). Expose it so the title
        // guard recognises an untouched "Filename.m4a" as auto-generated.
        let sourceFilename = (doc.sourceKind == .imported) ? doc.sourceURL : nil

        summarizingTranscriptID = transcriptID
        summarizationStage = .loadingModel(fraction: 0)

        summarizeTask = Task { [weak self, summaryEngine] in
            defer {
                Task { @MainActor in self?.summarizeTask = nil }
            }
            do {
                try await summaryEngine.ensureLoaded(model) { fraction in
                    Task { @MainActor in
                        self?.summarizationStage = .loadingModel(fraction: fraction)
                    }
                }
                await MainActor.run { self?.markDownloaded(model) }

                // --- Summary pass ---
                await MainActor.run {
                    self?.summarizationStage = .generatingSummary(text: "")
                }
                var summaryText = ""
                let summaryInstruction = customSummaryInstruction?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveSummaryInstruction: String =
                    (summaryInstruction?.isEmpty == false ? summaryInstruction! :
                        SummaryPrompts.summaryInstruction(for: language))
                let summaryPrompt =
                    effectiveSummaryInstruction
                    + "\n\nTranscript:\n" + feed
                let summaryStream = try await summaryEngine.stream(
                    prompt: summaryPrompt,
                    instructions: systemPrompt,
                    maxTokens: 600,
                    temperature: 0.3,
                    disableThinking: disableThinking
                )
                for try await chunk in summaryStream {
                    if Task.isCancelled { throw SummarizationError.cancelled }
                    summaryText += chunk
                    let visible = SummaryPrompts.stripThinking(summaryText)
                    await MainActor.run {
                        self?.summarizationStage = .generatingSummary(text: visible)
                    }
                }

                // Freeze the finalized summary so the UI keeps it visible
                // during the next streaming passes.
                let finalizedSummary = SummaryPrompts
                    .stripThinking(summaryText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // --- Action items pass ---
                await MainActor.run {
                    self?.summarizationStage = .generatingActions(
                        summary: finalizedSummary, text: "")
                }
                var actionsText = ""
                let actionsPrompt =
                    SummaryPrompts.actionItemsInstruction(for: language)
                    + "\n\nTranscript:\n" + feed
                let actionsStream = try await summaryEngine.stream(
                    prompt: actionsPrompt,
                    instructions: systemPrompt,
                    maxTokens: 600,
                    temperature: 0.1,
                    disableThinking: disableThinking
                )
                for try await chunk in actionsStream {
                    if Task.isCancelled { throw SummarizationError.cancelled }
                    actionsText += chunk
                    let visible = SummaryPrompts.stripThinking(actionsText)
                    await MainActor.run {
                        self?.summarizationStage = .generatingActions(
                            summary: finalizedSummary, text: visible)
                    }
                }

                let finalizedActions = SummaryPrompts.stripThinking(actionsText)

                // --- Title pass (short, one-line) ---
                await MainActor.run {
                    self?.summarizationStage = .generatingTitle(
                        summary: finalizedSummary, actions: finalizedActions)
                }
                var titleText = ""
                let titlePrompt =
                    SummaryPrompts.titleInstruction(for: language)
                    + "\n\nTranscript:\n" + feed
                let titleStream = try await summaryEngine.stream(
                    prompt: titlePrompt,
                    instructions: systemPrompt,
                    maxTokens: 40,
                    temperature: 0.2,
                    disableThinking: disableThinking
                )
                for try await chunk in titleStream {
                    if Task.isCancelled { throw SummarizationError.cancelled }
                    titleText += chunk
                }

                let parsedActions = SummaryPrompts.parseActionItems(finalizedActions)
                let finalTitle    = SummaryPrompts.sanitizeTitle(titleText)
                let modelShort    = model.shortName

                await MainActor.run {
                    guard let self else { return }
                    guard let idx = self.transcripts.firstIndex(where: { $0.id == transcriptID })
                    else { return }
                    var updated = self.transcripts[idx]
                    updated.summary = finalizedSummary
                    updated.actionItems = parsedActions
                    updated.summaryModelShortName = modelShort
                    updated.summaryGeneratedAt = Date()
                    // Replace the placeholder "Recording — <date>" / "Google Meet — <slug>"
                    // style titles but preserve anything the user has edited.
                    if !finalTitle.isEmpty,
                       self.shouldReplaceTitle(currentTitle, sourceFilename: sourceFilename) {
                        updated.title = finalTitle
                    }
                    self.transcripts[idx] = updated
                    try? TranscriptStore.shared.save(updated, audioSource: nil)
                    self.summarizationStage = .done
                    self.summarizingTranscriptID = nil
                    self.scheduleIdleUnload()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.summarizationStage = .idle
                    self?.summarizingTranscriptID = nil
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self?.summarizationStage = .error(msg)
                    self?.summarizingTranscriptID = nil
                }
            }
        }
    }

    func cancelSummarization() {
        summarizeTask?.cancel()
    }

    /// Arm a one-shot timer that drops the resident model if the user doesn't
    /// kick off another summary within `idleUnloadAfterSeconds`. Also releases
    /// MLX's allocator cache immediately so we're not sitting on multi-GB of
    /// reusable buffers between runs.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = idleUnloadAfterSeconds
        idleUnloadTask = Task { [weak self, summaryEngine] in
            await summaryEngine.releaseCaches()
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            } catch {
                return // cancelled by a new summarize call
            }
            await summaryEngine.unload()
            await MainActor.run {
                self?.idleUnloadTask = nil
            }
        }
    }

    private func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    /// Decide whether we're allowed to overwrite the transcript title with
    /// an LLM-generated one. User-edited titles are preserved; the auto-
    /// generated fallbacks are not.
    ///
    /// The fallbacks we recognise:
    /// • `"Recording — <date>"` for unnamed live recordings
    /// • `"Google Meet — <slug>"` / Zoom / Teams / Whereby for meeting drops
    /// • The raw imported filename (from `sourceURL`) — or anything ending in
    ///   a common audio/video extension, as a belt-and-suspenders catch
    private func shouldReplaceTitle(_ current: String, sourceFilename: String?) -> Bool {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("Recording — ") { return true }
        let meetingPrefixes = ["Google Meet — ", "Zoom — ", "Teams — ", "Whereby — "]
        if meetingPrefixes.contains(where: trimmed.hasPrefix) { return true }
        if let sourceFilename, trimmed == sourceFilename { return true }
        let audioVideoExts = [".m4a", ".mp3", ".mp4", ".mov", ".wav",
                              ".mpeg", ".mpeg4", ".aif", ".aiff", ".flac", ".webm"]
        let lower = trimmed.lowercased()
        if audioVideoExts.contains(where: lower.hasSuffix) { return true }
        return false
    }

    // MARK: – Recording state
    enum RecordingState: Equatable {
        case idle
        case preparing
        case recording(startedAt: Date, meeting: DetectedMeeting?, language: TranscriptionLanguage)
        case stopping
        case processing(progress: Double, stage: String)

        var isRecording: Bool { if case .recording = self { return true } else { return false } }
        var isBusy: Bool { if case .idle = self { return false } else { return true } }
    }
    var recordingState: RecordingState = .idle
    var elapsedSeconds: Int = 0
    var currentLevelRMS: Float = 0
    var isMicMuted: Bool = false

    // MARK: – Meeting detection (sheet is item-driven off this)
    var detectedMeeting: DetectedMeeting? = nil
    var dismissedMeetingURLs: Set<String> = []

    // MARK: – Library
    var transcripts: [TranscriptDocument] = []
    var selectedTranscriptID: String? = nil

    // MARK: – UI triggers
    var importPanelRequested: Bool = false
    var lastError: String? = nil

    // Collaborators
    private var detector: MeetingDetector?
    private var recorder: RecordingCoordinator?
    private var elapsedTimer: Timer?
    private var didBootstrap = false

    // MARK: – Bootstrap
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await loadTranscripts()
        startMeetingDetection()
    }

    func loadTranscripts() async {
        do {
            let loaded = try TranscriptStore.shared.loadAll()
            self.transcripts = loaded.sorted { $0.date > $1.date }
        } catch {
            self.lastError = "Could not load transcripts: \(error.localizedDescription)"
        }
    }

    // MARK: – Meeting detection
    private func startMeetingDetection() {
        let det = MeetingDetector()
        det.onMeetingDetected = { [weak self] meeting in
            Task { @MainActor in
                guard let self else { return }
                if self.dismissedMeetingURLs.contains(meeting.url) { return }
                if self.recordingState.isBusy { return }
                self.detectedMeeting = meeting
            }
        }
        det.start()
        self.detector = det
    }

    func dismissDetectedMeeting() {
        if let url = detectedMeeting?.url {
            dismissedMeetingURLs.insert(url)
        }
        detectedMeeting = nil
    }

    // MARK: – Recording lifecycle
    func startRecording(language: TranscriptionLanguage, meeting: DetectedMeeting?) async {
        guard case .idle = recordingState else { return }
        recordingState = .preparing
        let coord = RecordingCoordinator()
        self.recorder = coord
        do {
            try await coord.start(captureSystemAudio: captureSystemAudio) { [weak self] rms in
                Task { @MainActor in self?.currentLevelRMS = rms }
            }
            let start = Date()
            recordingState = .recording(startedAt: start, meeting: meeting, language: language)
            elapsedSeconds = 0
            startElapsedTimer(from: start)
            if let url = meeting?.url { dismissedMeetingURLs.insert(url) }
            detectedMeeting = nil
        } catch {
            recordingState = .idle
            lastError = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func setMicMuted(_ muted: Bool) {
        isMicMuted = muted
        recorder?.setMicMuted(muted)
    }

    func stopRecording() async {
        guard case .recording(let startedAt, let meeting, let language) = recordingState else { return }
        recordingState = .stopping
        stopElapsedTimer()
        guard let recorder = recorder else { recordingState = .idle; return }
        do {
            let stems = try await recorder.stop()
            let duration = Date().timeIntervalSince(startedAt)
            await runPipeline(voiceURL: stems.voiceURL,
                              systemURL: stems.systemURL,
                              duration: duration,
                              language: language,
                              meeting: meeting,
                              sourceKind: .live)
        } catch {
            recordingState = .idle
            lastError = "Stop failed: \(error.localizedDescription)"
        }
        self.recorder = nil
    }

    private func startElapsedTimer(from start: Date) {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.recordingState.isRecording {
                    self.elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: – Import path
    func importFile(url sourceURL: URL, language: TranscriptionLanguage) async {
        guard case .idle = recordingState else { return }
        recordingState = .processing(progress: 0.0, stage: "Decoding audio")
        do {
            let wavURL = try await MediaImporter.convertToMono16kWav(source: sourceURL) { [weak self] fraction in
                Task { @MainActor in
                    self?.recordingState = .processing(progress: fraction * 0.2,
                                                       stage: "Decoding audio")
                }
            }
            let duration = try await MediaImporter.duration(of: sourceURL)
            // Imports: treat the whole file as a single "voice" stem (no system split).
            await runPipeline(voiceURL: wavURL,
                              systemURL: nil,
                              duration: duration,
                              language: language,
                              meeting: nil,
                              sourceKind: .imported,
                              importedName: sourceURL.lastPathComponent,
                              progressOffset: 0.2)
        } catch {
            recordingState = .idle
            lastError = "Import failed: \(error.localizedDescription)"
        }
    }

    private func runPipeline(voiceURL: URL,
                             systemURL: URL?,
                             duration: TimeInterval,
                             language: TranscriptionLanguage,
                             meeting: DetectedMeeting?,
                             sourceKind: TranscriptDocument.SourceKind,
                             importedName: String? = nil,
                             progressOffset: Double = 0.0) async {
        recordingState = .processing(progress: progressOffset + 0.05, stage: "Loading Whisper")
        let pipeline = TranscriptionPipeline()
        do {
            let progress: (Double, String) -> Void = { [weak self] p, s in
                Task { @MainActor in
                    self?.recordingState = .processing(
                        progress: progressOffset + (1.0 - progressOffset) * p,
                        stage: s)
                }
            }
            let prime = languagePrimes[language.rawValue] ?? ""
            let doc = try await pipeline.run(voiceURL: voiceURL,
                                             systemURL: systemURL,
                                             duration: duration,
                                             language: language,
                                             model: selectedModel,
                                             meeting: meeting,
                                             sourceKind: sourceKind,
                                             importedFileName: importedName,
                                             initialPrompt: prime.isEmpty ? nil : prime,
                                             wordReplacements: wordReplacements,
                                             progress: progress)
            try TranscriptStore.shared.save(doc, audioSource: voiceURL)
            await loadTranscripts()
            selectedTranscriptID = doc.id
            recordingState = .idle
        } catch {
            lastError = "Transcription failed: \(error.localizedDescription)"
            recordingState = .idle
        }
    }

    // MARK: – Transcript deletion
    /// Remove the transcript from the library and delete all on-disk files
    /// (markdown, JSON, and paired WAV stems). If the deleted transcript was
    /// selected, clears the selection so the detail view returns to Record.
    func deleteTranscript(id: String) {
        guard let idx = transcripts.firstIndex(where: { $0.id == id }) else { return }
        let doc = transcripts[idx]
        TranscriptStore.shared.delete(doc)
        transcripts.remove(at: idx)
        if selectedTranscriptID == id {
            selectedTranscriptID = nil
        }
    }

    // MARK: – Transcript edits
    func renameTranscript(id: String, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = transcripts.firstIndex(where: { $0.id == id }) else { return }
        transcripts[idx].title = trimmed
        try? TranscriptStore.shared.save(transcripts[idx], audioSource: nil)
    }

    func renameSpeaker(transcriptID: String, speakerID: Int, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let tIdx = transcripts.firstIndex(where: { $0.id == transcriptID }),
              let sIdx = transcripts[tIdx].speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        transcripts[tIdx].speakers[sIdx].name = trimmed
        try? TranscriptStore.shared.save(transcripts[tIdx], audioSource: nil)
    }
}
