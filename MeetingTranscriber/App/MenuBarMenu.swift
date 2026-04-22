import SwiftUI

/// Dropdown contents of the menu-bar extra.
struct MenuBarMenu: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // State summary
        Text(stateLine)
        if let queueLine { Text(queueLine).foregroundStyle(.secondary) }
        Divider()

        switch state.recordingState {
        case .idle:
            Button("Start Recording (\(state.defaultLanguage.displayName))") {
                Task { await state.startRecording(language: state.defaultLanguage, meeting: nil) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        case .recording:
            Button("Stop Recording") {
                Task { await state.stopRecording() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button(state.isMicMuted ? "Unmute Microphone" : "Mute Microphone") {
                state.setMicMuted(!state.isMicMuted)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        case .preparing, .stopping:
            EmptyView()
        }

        Divider()

        Menu("Default Language") {
            Picker("Language", selection: Bindable(state).defaultLanguage) {
                ForEach(TranscriptionLanguage.allCases) { lang in
                    Text("\(lang.flag) \(lang.displayName)").tag(lang)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(state.recordingState.isBusy)

        Divider()

        Button("Show Window") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Divider()

        Button("Quit Meeting Transcriber") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var stateLine: String {
        switch state.recordingState {
        case .idle:
            return "Idle"
        case .preparing:
            return "Preparing…"
        case .recording(_, let meeting, let lang):
            let who = meeting?.title ?? "Recording"
            return "\(who) · \(lang.displayName)"
        case .stopping:
            return "Stopping…"
        }
    }

    /// Secondary line shown under the main state summary when background
    /// transcription is running, e.g. "Transcribing · +2 queued".
    private var queueLine: String? {
        guard state.isProcessing else { return nil }
        let queued = state.queuedJobCount
        return queued > 0 ? "Transcribing · +\(queued) queued" : "Transcribing"
    }
}
