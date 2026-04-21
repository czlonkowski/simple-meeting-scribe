import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Dictionary", systemImage: "character.book.closed") {
                DictionarySettingsView()
            }
            Tab("Summary", systemImage: "sparkles") {
                SummarySettingsView()
            }
        }
        .scenePadding()
        .frame(minWidth: 620, minHeight: 520)
    }
}

// MARK: – General

private struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Transcription") {
                Picker("Model", selection: $state.selectedModel) {
                    ForEach(WhisperModel.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Picker("Default language", selection: $state.defaultLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { l in
                        Text("\(l.flag) \(l.displayName)").tag(l)
                    }
                }
            }
            Section("Capture") {
                Toggle("Include Arc system audio by default", isOn: $state.captureSystemAudio)
            }
            Section("Storage") {
                LabeledContent("Transcripts folder") {
                    Button(TranscriptStore.shared.rootURL.path(percentEncoded: false)) {
                        NSWorkspace.shared.open(TranscriptStore.shared.rootURL)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: – Dictionary

private struct DictionarySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var language: TranscriptionLanguage = .english
    @State private var primeDraft: String = ""
    @State private var primeSavedHint: Bool = false

    // Replacement row editing
    @State private var selectedReplacementIDs: Set<UUID> = []
    @State private var newOriginal: String = ""
    @State private var newReplacement: String = ""

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    ForEach(TranscriptionLanguage.allCases) { l in
                        Text("\(l.flag) \(l.displayName)").tag(l)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextEditor(text: $primeDraft)
                    .font(.body)
                    .frame(minHeight: 80)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.15))
                    )

                HStack {
                    Text("Style-primes Whisper for punctuation, casing, and diacritics. Also nudges it toward vocabulary it sees here — but don't rely on it for rare words; use Replacements below instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to default") {
                        primeDraft = DictionaryStore.defaultPrimes[language.rawValue] ?? ""
                        appState.setPrime(primeDraft, for: language)
                        flashSaved()
                    }
                    .controlSize(.small)
                    Button(primeSavedHint ? "Saved ✓" : "Save prime") {
                        appState.setPrime(primeDraft, for: language)
                        flashSaved()
                    }
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(primeDraft == appState.languagePrimes[language.rawValue])
                }
            } header: {
                Text("Prime")
            }

            Section {
                Table(appState.wordReplacements, selection: $selectedReplacementIDs) {
                    TableColumn("") { entry in
                        Toggle("", isOn: Binding(
                            get: { entry.isEnabled },
                            set: { isOn in
                                var copy = entry
                                copy.isEnabled = isOn
                                appState.updateReplacement(copy)
                            }
                        ))
                        .labelsHidden()
                    }
                    .width(28)

                    TableColumn("Original (comma-separated)") { entry in
                        Text(entry.original).foregroundStyle(.primary)
                    }
                    TableColumn("Replacement") { entry in
                        Text(entry.replacement).foregroundStyle(.primary)
                    }
                }
                .frame(minHeight: 140)

                HStack(spacing: 8) {
                    TextField("Original, variants", text: $newOriginal)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    TextField("Replacement", text: $newReplacement)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        addReplacement()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newOriginal.trimmingCharacters(in: .whitespaces).isEmpty ||
                              newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(role: .destructive) {
                        appState.removeReplacements(withIDs: selectedReplacementIDs)
                        selectedReplacementIDs.removeAll()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedReplacementIDs.isEmpty)
                }
            } header: {
                Text("Replacements")
            } footer: {
                Text("Applied case-insensitively after transcription with word-boundary matching. Comma-separate variants that should all map to the same replacement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadPrime() }
        .onChange(of: language) { _, _ in loadPrime() }
    }

    private func loadPrime() {
        primeDraft = appState.languagePrimes[language.rawValue]
            ?? DictionaryStore.defaultPrimes[language.rawValue]
            ?? ""
    }

    private func addReplacement() {
        let original = newOriginal.trimmingCharacters(in: .whitespaces)
        let replacement = newReplacement.trimmingCharacters(in: .whitespaces)
        guard !original.isEmpty, !replacement.isEmpty else { return }
        appState.addReplacement(WordReplacement(original: original, replacement: replacement))
        newOriginal = ""
        newReplacement = ""
    }

    private func flashSaved() {
        primeSavedHint = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            primeSavedHint = false
        }
    }
}

// MARK: – Summary

private struct SummarySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var englishPromptDraft: String = ""
    @State private var polishPromptDraft: String = ""
    @State private var englishPromptSaved: Bool = false
    @State private var polishPromptSaved: Bool = false

    var body: some View {
        @Bindable var state = appState

        Form {
            Section {
                Picker("English", selection: Binding(
                    get: { appState.defaultModelEnglish },
                    set: { appState.setDefaultModel($0, for: .english) }
                )) {
                    ForEach(LanguageModel.allCases.filter { $0.supportedLanguages.contains(.english) }) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Picker("Polish", selection: Binding(
                    get: { appState.defaultModelPolish },
                    set: { appState.setDefaultModel($0, for: .polish) }
                )) {
                    ForEach(LanguageModel.allCases.filter { $0.supportedLanguages.contains(.polish) }) { m in
                        Text(m.displayName).tag(m)
                    }
                }
            } header: {
                Text("Default model per language")
            } footer: {
                Text("The matching model is used automatically based on the transcript's language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(LanguageModel.allCases) { model in
                    ModelLibraryRow(model: model)
                }
            } header: {
                Text("Model library")
            } footer: {
                Text("Pre-download models so the first summary is instant. Files live under ~/Documents/huggingface/models/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("English (Qwen3.5)").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $englishPromptDraft)
                        .font(.body)
                        .frame(minHeight: 64)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                    HStack {
                        Spacer()
                        Button("Reset") {
                            englishPromptDraft = SummaryStore.defaultSystemPrompt(for: .english)
                            appState.setSystemPrompt(englishPromptDraft, for: .english)
                        }
                        .controlSize(.small)
                        Button(englishPromptSaved ? "Saved ✓" : "Save") {
                            appState.setSystemPrompt(englishPromptDraft, for: .english)
                            flash(\.englishPromptSaved)
                        }
                        .controlSize(.small)
                        .disabled(englishPromptDraft == appState.systemPromptEnglish)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Polish (Bielik)").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $polishPromptDraft)
                        .font(.body)
                        .frame(minHeight: 64)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                    HStack {
                        Spacer()
                        Button("Reset") {
                            polishPromptDraft = SummaryStore.defaultSystemPrompt(for: .polish)
                            appState.setSystemPrompt(polishPromptDraft, for: .polish)
                        }
                        .controlSize(.small)
                        Button(polishPromptSaved ? "Saved ✓" : "Save") {
                            appState.setSystemPrompt(polishPromptDraft, for: .polish)
                            flash(\.polishPromptSaved)
                        }
                        .controlSize(.small)
                        .disabled(polishPromptDraft == appState.systemPromptPolish)
                    }
                }
            } header: {
                Text("System prompts")
            }

            Section("Runtime") {
                Button("Unload current model") {
                    Task { await appState.unloadSummaryModel() }
                }
                .help("Free the memory used by the currently resident summarization model.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            englishPromptDraft = appState.systemPromptEnglish
            polishPromptDraft  = appState.systemPromptPolish
        }
    }

    private func flash(_ keyPath: ReferenceWritableKeyPath<SummarySettingsView, Bool>) {
        // Since this is a value-type view, we mutate state via the @State storage.
        // Trick: toggle via a Task that flips the matching @State.
        switch keyPath {
        case \SummarySettingsView.englishPromptSaved:
            englishPromptSaved = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                englishPromptSaved = false
            }
        case \SummarySettingsView.polishPromptSaved:
            polishPromptSaved = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                polishPromptSaved = false
            }
        default: break
        }
    }
}

private struct ModelLibraryRow: View {
    let model: LanguageModel
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.headline)
                Text(model.repoID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(String(format: "~%.1f GB download · ~%.0f GB active",
                            model.approxDownloadGB, model.approxActiveMemoryGB))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()

            switch appState.modelState(for: model) {
            case .notDownloaded:
                Button {
                    appState.downloadModel(model)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)

            case .downloading(let fraction):
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: fraction).frame(width: 120)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button {
                    appState.cancelDownload(model)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .controlSize(.small)

            case .downloaded:
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                Button(role: .destructive) {
                    appState.deleteModel(model)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
