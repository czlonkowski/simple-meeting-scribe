import SwiftUI

struct MeetingJoinSheet: View {
    let meeting: DetectedMeeting
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.red)
                    .padding(10)
                    .glassEffect(.regular.tint(.red.opacity(0.15)), in: .circle)
                Text("Meeting detected")
                    .font(.title2.weight(.semibold))
                Text(meeting.title)
                    .foregroundStyle(.secondary)
                Text(meeting.platform)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)

            VStack(spacing: 10) {
                Text("Record this meeting in:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
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
        }
        .padding(28)
        .frame(width: 440)
    }

    private func languageButton(_ language: TranscriptionLanguage) -> some View {
        Button {
            Task { await appState.startRecording(language: language, meeting: meeting) }
            dismiss()
        } label: {
            VStack(spacing: 4) {
                Text(language.flag).font(.system(size: 28))
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
