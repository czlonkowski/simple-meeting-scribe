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
                if appState.isProcessing {
                    processingPanel
                }
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
                if let mic = appState.currentInputDeviceName {
                    Text("·").foregroundStyle(.tertiary)
                    Label(mic, systemImage: "mic.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }
                if appState.isMicMuted {
                    Text("·").foregroundStyle(.tertiary)
                    Label("Mic muted", systemImage: "mic.slash.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.headline)

            VStack(spacing: 10) {
                LevelMeterRow(label: "Mic",
                              systemImage: appState.isMicMuted ? "mic.slash.fill" : "mic.fill",
                              level: appState.isMicMuted ? 0 : appState.currentMicRMS,
                              muted: appState.isMicMuted)
                if appState.captureSystemAudio {
                    LevelMeterRow(label: "System",
                                  systemImage: "speaker.wave.2.fill",
                                  level: appState.currentSystemRMS,
                                  muted: false)
                }
            }
        }
    }

    // MARK: – Processing queue panel (shown below the state card)
    @ViewBuilder
    private var processingPanel: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path")
                        .foregroundStyle(.secondary)
                    Text("Transcribing in background")
                        .font(.headline)
                    Spacer()
                    if appState.queuedJobCount > 0 {
                        Text("+\(appState.queuedJobCount) queued")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }

                if let job = appState.activeJob,
                   case .running(let progress, let stage) = job.stage {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(job.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text(stage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Queued…").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// Classic LED-style VU meter. One row of vertical segments filling
/// left-to-right as the RMS rises: green (safe) → yellow (loud) → red (peak).
private struct LevelMeterRow: View {
    let label: String
    let systemImage: String
    /// Raw RMS from the capture path (roughly 0…0.3 for speech, much higher
    /// when the source is clipping). Scaled up by `gain` before mapping to
    /// segments, so a 0.15 RMS lights most of the green zone.
    let level: Float
    let muted: Bool

    private let segmentCount = 20
    private let gain: Float = 6
    /// Fraction of segments that burn green / yellow — the remainder is red.
    private let greenFraction: Float = 0.65
    private let yellowFraction: Float = 0.85

    var body: some View {
        HStack(spacing: 10) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(muted ? Color.orange : .secondary)
                .frame(width: 78, alignment: .leading)

            GeometryReader { geo in
                let spacing: CGFloat = 3
                let totalSpacing = spacing * CGFloat(segmentCount - 1)
                let segmentWidth = max(2, (geo.size.width - totalSpacing) / CGFloat(segmentCount))
                let scaled = min(1, max(0, Double(level * gain)))
                let litCount = Int((scaled * Double(segmentCount)).rounded())

                HStack(spacing: spacing) {
                    ForEach(0..<segmentCount, id: \.self) { idx in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color(for: idx, litCount: litCount))
                            .frame(width: segmentWidth)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: litCount)
            }
            .frame(height: 12)
        }
    }

    private func color(for index: Int, litCount: Int) -> Color {
        let lit = index < litCount
        let position = Float(index) / Float(segmentCount - 1)
        let hot: Color
        switch position {
        case ..<greenFraction:    hot = .green
        case ..<yellowFraction:   hot = .yellow
        default:                  hot = .red
        }
        return lit ? hot : Color.primary.opacity(0.08)
    }
}
