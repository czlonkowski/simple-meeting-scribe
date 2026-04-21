import SwiftUI

struct RecordView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        ScrollView {
            VStack(spacing: 24) {
                header
                stateCard
                controls
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: – Header
    private var header: some View {
        @Bindable var state = appState
        return HStack(alignment: .firstTextBaseline) {
            Text("Record")
                .font(Theme.titleFont)
            Spacer()
            Picker("Model", selection: $state.selectedModel) {
                ForEach(WhisperModel.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
            .disabled(state.recordingState.isBusy)
        }
    }

    // MARK: – State card
    private var stateCard: some View {
        GlassCard {
            VStack(spacing: 20) {
                switch appState.recordingState {
                case .idle:              idleCenter
                case .preparing:         preparingCenter
                case .recording(_, let meeting, let lang):
                    recordingCenter(meeting: meeting, language: lang)
                case .stopping:
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Stopping…").foregroundStyle(.secondary)
                    }
                case .processing(let progress, let stage):
                    processingCenter(progress: progress, stage: stage)
                }
            }
            .frame(minHeight: 200)
            .frame(maxWidth: .infinity)
        }
    }

    private var idleCenter: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.microphone")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ready")
                .font(.title2.weight(.medium))
            Text("Start a recording, or drop an audio/video file anywhere in the window to transcribe it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
    }

    private var preparingCenter: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Preparing…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func recordingCenter(meeting: DetectedMeeting?, language: TranscriptionLanguage) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 10, height: 10)
                    .opacity(appState.elapsedSeconds.isMultiple(of: 2) ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.6), value: appState.elapsedSeconds)
                Text(elapsedString)
                    .font(Theme.monoFont.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let meeting {
                    Text("·").foregroundStyle(.tertiary)
                    Label(meeting.title, systemImage: "video.fill")
                        .labelStyle(.titleAndIcon)
                }
                Text("·").foregroundStyle(.tertiary)
                Text("\(language.flag) \(language.displayName)")
                if appState.isMicMuted {
                    Text("·").foregroundStyle(.tertiary)
                    Label("Mic muted", systemImage: "mic.slash.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.headline)

            levelMeter
        }
    }

    private var levelMeter: some View {
        GeometryReader { geo in
            let width = CGFloat(max(0, min(1, Double(appState.currentLevelRMS) * 6))) * geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.green, .yellow, .orange, Theme.accent],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .animation(.easeOut(duration: 0.08), value: width)
            }
        }
        .frame(height: 8)
    }

    @ViewBuilder
    private func processingCenter(progress: Double, stage: String) -> some View {
        VStack(spacing: 14) {
            Text(stage).font(.headline)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
        }
    }

    // MARK: – Controls
    @ViewBuilder
    private var controls: some View {
        @Bindable var state = appState

        HStack(spacing: 16) {
            switch appState.recordingState {
            case .idle:
                Picker("Language", selection: $state.defaultLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { l in
                        Text("\(l.flag) \(l.displayName)").tag(l)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Toggle(isOn: $state.captureSystemAudio) {
                    Label("Include system audio", systemImage: "speaker.wave.2.fill")
                }
                .toggleStyle(.switch)

                Spacer()

                Button {
                    Task { await appState.startRecording(language: appState.defaultLanguage, meeting: nil) }
                } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .tint(Theme.accent)
                .keyboardShortcut("r", modifiers: [.command, .shift])

            case .recording:
                Button {
                    appState.setMicMuted(!appState.isMicMuted)
                } label: {
                    Label(appState.isMicMuted ? "Unmute" : "Mute mic",
                          systemImage: appState.isMicMuted ? "mic.slash.fill" : "mic.fill")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Spacer()

                Button {
                    Task { await appState.stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .tint(Theme.accent)
                .keyboardShortcut("r", modifiers: [.command, .shift])

            default:
                EmptyView()
            }
        }
    }

    private var elapsedString: String {
        let s = appState.elapsedSeconds
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}
