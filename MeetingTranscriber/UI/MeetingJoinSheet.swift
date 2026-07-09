import SwiftUI

struct MeetingJoinSheet: View {
    let meeting: DetectedMeeting
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric private var sheetIconSize: CGFloat = 38
    @ScaledMetric private var languageFlagSize: CGFloat = 28

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 22) {
            VStack(spacing: Theme.space3) {
                Image(systemName: "video.fill")
                    .font(.system(size: sheetIconSize))
                    .foregroundStyle(.red)
                    .padding(10)
                    .glassEffect(.regular.tint(.red.opacity(0.15)), in: .circle)
                Text("Meeting detected")
                    .font(.title2.weight(.semibold))
                    .tracking(-0.4)
                Text(meeting.title)
                    .foregroundStyle(.secondary)
                Text(meeting.platform)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, Theme.space2)

            VStack(spacing: Theme.space3) {
                Text("Transcription engine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Model", selection: $appState.selectedModel) {
                    ForEach(WhisperModel.allCases) { m in
                        Text(m.compactName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle(isOn: Binding(
                get: { appState.recordScreen },
                set: { appState.setRecordScreen($0) }
            )) {
                Label("Record screen", systemImage: "video.fill")
            }
            .toggleStyle(.switch)
            .help("Record the meeting's browser window as video")

            VStack(spacing: 10) {
                Text("Record this meeting in:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                GlassEffectContainer(spacing: Theme.space6) {
                    HStack(spacing: Theme.space6) {
                        languageButton(.english)
                        languageButton(.polish)
                    }
                }
            }

            Button("Ignore", role: .cancel) {
                appState.dismissDetectedMeeting()
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.pressable)
        }
        .padding(28)
        .frame(width: 440)
    }

    private func languageButton(_ language: TranscriptionLanguage) -> some View {
        Button {
            Task { await appState.startRecording(language: language, meeting: meeting) }
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
        .tint(.red)
        .keyboardShortcut(language == .english ? "e" : "p", modifiers: [.command])
    }
}
