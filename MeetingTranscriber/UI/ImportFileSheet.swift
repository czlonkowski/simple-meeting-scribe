import SwiftUI

/// Shown when the user drops a media file into the window or picks one via
/// Browse/Import. Lets them hand-pick the transcription engine and language
/// for this file — the engine choice is local to the sheet, so it doesn't
/// disturb the global model selection.
struct ImportFileSheet: View {
    let url: URL
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model: WhisperModel = .largeV3Turbo
    @ScaledMetric private var sheetIconSize: CGFloat = 38
    @ScaledMetric private var languageFlagSize: CGFloat = 28

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: Theme.space3) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: sheetIconSize))
                    .foregroundStyle(Theme.accent)
                    .padding(10)
                    .glassEffect(.regular.tint(Theme.accent.opacity(0.15)), in: .circle)
                Text("Import file")
                    .font(.title2.weight(.semibold))
                    .tracking(-0.4)
                Text(url.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
            }
            .padding(.top, Theme.space2)

            VStack(spacing: Theme.space3) {
                Text("Transcription engine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Model", selection: $model) {
                    ForEach(WhisperModel.allCases) { m in
                        Text(m.compactName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(spacing: 10) {
                Text("Transcribe in:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                GlassEffectContainer(spacing: Theme.space6) {
                    HStack(spacing: Theme.space6) {
                        languageButton(.english)
                        languageButton(.polish)
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.pressable)
        }
        .padding(28)
        .frame(width: 440)
        .onAppear { model = appState.selectedModel }
    }

    private func languageButton(_ language: TranscriptionLanguage) -> some View {
        Button {
            Task { await appState.importFile(url: url, language: language, model: model) }
            dismiss()
        } label: {
            VStack(spacing: Theme.space2) {
                Text(language.flag).font(.system(size: languageFlagSize))
                Text(language.displayName).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .tint(Theme.accent)
        .keyboardShortcut(language == .english ? "e" : "p", modifiers: [.command])
    }
}
