import SwiftUI

/// Detail for a recording that was never transcribed: what is on disk, why the
/// last attempt failed, playback, and a manual Transcribe action.
struct PendingRecordingDetailView: View {
    let pendingID: String
    @Environment(AppState.self) private var appState

    @State private var audioPlayer = TranscriptAudioPlayer()
    @State private var language: TranscriptionLanguage = .polish
    @State private var confirmDelete = false

    private var pending: PendingRecording? {
        appState.visiblePendingRecordings.first { $0.id == pendingID }
    }

    var body: some View {
        if let pending {
            content(for: pending)
                .task(id: pending.id) {
                    language = pending.sidecar?.language ?? appState.defaultLanguage
                    await loadAudio(for: pending)
                }
                .onDisappear { audioPlayer.unload() }
        } else {
            ContentUnavailableView(
                "Recording not found",
                systemImage: "waveform.slash",
                description: Text("It may have been transcribed or deleted.")
            )
        }
    }

    private func content(for pending: PendingRecording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(for: pending)
                statusCard(for: pending)
                if audioPlayer.url != nil {
                    AudioPlayerCard(player: audioPlayer)
                }
            }
            .padding(32)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("Delete “\(pending.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                appState.deletePendingRecording(id: pending.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Removes the audio recordings and video of this meeting. This cannot be undone.")
        }
    }

    private func header(for pending: PendingRecording) -> some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text(pending.title)
                .font(Theme.titleFont)
                .tracking(-0.4)

            HStack(spacing: Theme.space4) {
                Label(pending.startedAt.formatted(date: .abbreviated, time: .shortened),
                      systemImage: "calendar")
                Text("·")
                Label(PendingRecordingRow.formatDuration(pending.estimatedDuration), systemImage: "clock")
                if pending.systemFileName != nil {
                    Text("·")
                    Label("System audio", systemImage: "speaker.wave.2")
                }
                if pending.videoFileName != nil {
                    Text("·")
                    Label("Video", systemImage: "video")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusCard(for pending: PendingRecording) -> some View {
        VStack(alignment: .leading, spacing: Theme.space6) {
            Label {
                Text(pending.sidecar?.lastError != nil
                     ? "Transcription failed"
                     : "This recording was not transcribed")
                    .font(Theme.sectionTitleFont)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if let error = pending.sidecar?.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The app quit or stopped before the transcript was saved. The audio is safe on disk; transcribe it when you're ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let job = appState.recoveryJob(for: pending) {
                HStack(spacing: Theme.space3) {
                    ProgressView().controlSize(.small)
                    Text(progressLabel(for: job))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                actions(for: pending)
            }
        }
        .padding(Theme.innerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radiusMedium))
    }

    private func actions(for pending: PendingRecording) -> some View {
        HStack(spacing: Theme.space6) {
            Picker("Language", selection: $language) {
                ForEach(TranscriptionLanguage.allCases) { lang in
                    Text("\(lang.flag) \(lang.displayName)").tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Menu {
                ForEach(WhisperModel.allCases) { model in
                    Button("with \(model.displayName)") {
                        appState.transcribePending(id: pending.id, language: language, model: model)
                    }
                }
            } label: {
                Label("Transcribe", systemImage: "waveform")
            } primaryAction: {
                appState.transcribePending(id: pending.id, language: language)
            }
            .fixedSize()
            .help("Transcribe with the default engine. Use the arrow to pick another engine.")

            Spacer()

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .controlSize(.regular)
    }

    private func progressLabel(for job: AppState.ProcessingJob) -> String {
        switch job.stage {
        case .queued:                    "Queued for transcription"
        case .running(let p, let stage): "\(stage) · \(Int(p * 100))%"
        case .failed(let msg):           "Failed: \(msg)"
        }
    }

    /// Opening the recording fixes its header first (the user chose to look at
    /// it), so a stem cut off by a crash plays instead of looking empty.
    private func loadAudio(for pending: PendingRecording) async {
        guard let stems = await AppState.repairedStems(for: pending) else {
            audioPlayer.unload()
            return
        }
        audioPlayer.load(voiceURL: stems.voice, systemURL: stems.system)
    }
}
