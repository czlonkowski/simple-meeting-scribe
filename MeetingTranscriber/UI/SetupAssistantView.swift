import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI
import UserNotifications

/// First-run setup: picks the defaults a new user would otherwise have to find
/// across four Settings tabs. Every choice stays editable in Settings, and the
/// assistant can be reopened from the app menu or Settings › General.
struct SetupAssistantView: View {
    @Environment(AppState.self) private var appState

    private enum Step: Int, CaseIterable {
        case welcome, transcription, summaries, meetings, permissions
    }

    private enum Engine: Hashable {
        case cloud, local
    }

    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var engine: Engine = .local
    @State private var localModel: WhisperModel = .largeV3Turbo
    @State private var endpoint = ""
    @State private var azureKey = ""
    @State private var elevenLabsKey = ""
    @State private var summaryInCloud = false
    @State private var language: TranscriptionLanguage = .english

    private var cloudEngine: WhisperModel? {
        SetupDefaults.cloudEngine(
            hasMAIKey: !azureKey.trimmed.isEmpty
                && MAITranscribeEngine.transcribeURL(endpoint: endpoint.trimmed) != nil,
            hasScribeKey: !elevenLabsKey.trimmed.isEmpty
        )
    }

    private var canContinue: Bool {
        step != .transcription || engine == .local || cloudEngine != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                .tint(Theme.accent)
                .padding(.bottom, Theme.space12)

            Group {
                switch step {
                case .welcome: welcome
                case .transcription: transcription
                case .summaries: summaries
                case .meetings: meetings
                case .permissions: PermissionsStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step == .welcome {
                    Button("Skip Setup") { appState.completeSetup() }
                        .help("Keep the current defaults; change them later in Settings")
                } else {
                    Button("Back") { go(-1) }
                }
                Spacer()
                if step == .permissions {
                    Button("Done") { finish() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { go(1) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                }
            }
            .padding(.top, Theme.space8)
        }
        .padding(Theme.space12)
        .frame(width: 600, height: 540)
        .onAppear(perform: load)
    }

    // MARK: – Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.space8) {
            title("Welcome to Simple Meeting Scribe",
                  "Record a meeting or call, get a transcript with speakers, then a summary and action items. A few choices first — all of them can be changed later in Settings.")
            TextField("Your name", text: $name, prompt: Text("e.g. Anna"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Text("Used in place of \"You\" in transcripts and summaries. Optional.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transcription: some View {
        VStack(alignment: .leading, spacing: Theme.space8) {
            title("How should meetings be transcribed?",
                  "You can still pick a different engine for any single meeting.")
            choice(.cloud, symbol: "cloud",
                   heading: "Cloud — fast and accurate",
                   detail: "An hour of audio in under a minute, best speaker separation. Uses your own Azure Speech or ElevenLabs key; audio goes to that account.")
            choice(.local, symbol: "lock.laptopcomputer",
                   heading: "On this Mac — private",
                   detail: "Audio never leaves the Mac and works offline. Slower; the model downloads on first use.")

            if engine == .cloud {
                VStack(alignment: .leading, spacing: Theme.space4) {
                    Grid(alignment: .leading, horizontalSpacing: Theme.space6, verticalSpacing: Theme.space4) {
                        GridRow {
                            Text("Azure endpoint").gridColumnAlignment(.trailing)
                            TextField("Azure endpoint", text: $endpoint,
                                      prompt: Text(verbatim: "https://<resource>.cognitiveservices.azure.com/"))
                        }
                        GridRow {
                            Text("Azure Speech key")
                            SecureField("Azure Speech key", text: $azureKey, prompt: Text("For MAI-Transcribe-2"))
                        }
                        GridRow {
                            Text("ElevenLabs key")
                            SecureField("ElevenLabs key", text: $elevenLabsKey, prompt: Text("Optional, for Scribe v2"))
                        }
                    }
                    .labelsHidden()
                    Text(cloudEngine == nil
                         ? "Add an Azure Speech endpoint and key, or an ElevenLabs key."
                         : "Keys are stored in the macOS Keychain. With both, MAI is used and Scribe takes over if MAI fails.")
                        .font(.caption)
                        .foregroundStyle(cloudEngine == nil ? .orange : .secondary)
                }
                .textFieldStyle(.roundedBorder)
            } else {
                Picker("Model", selection: $localModel) {
                    Text("Whisper Large v3 Turbo — best for Polish").tag(WhisperModel.largeV3Turbo)
                    Text("Parakeet v3 — fastest").tag(WhisperModel.parakeetV3)
                }
                .pickerStyle(.radioGroup)
            }
        }
    }

    private var summaries: some View {
        VStack(alignment: .leading, spacing: Theme.space8) {
            title("Summaries and action items",
                  "Optional. Transcripts work without them.")
            Picker("", selection: $summaryInCloud) {
                Text("On this Mac with Gemma 4 12B (~7 GB, 32 GB RAM recommended)").tag(false)
                Text("With my Azure OpenAI deployment").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if summaryInCloud {
                Text("Add the deployment in Settings › Summary after setup, then pick it as the default model there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LocalSummaryModelRow(model: SummaryStore.defaultModel(for: language))
            }
        }
    }

    private var meetings: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: Theme.space8) {
            title("Meetings and calls",
                  "Meetings in Arc, Safari or Chrome are detected and you're asked to record. Calls can start recording by themselves.")
            Form {
                Picker("Usual meeting language", selection: $language) {
                    ForEach(TranscriptionLanguage.allCases) { l in
                        Text("\(l.flag) \(l.displayName)").tag(l)
                    }
                }
                Toggle("Record WhatsApp, iPhone and other calls automatically", isOn: Binding(
                    get: { state.autoRecordCalls }, set: { state.setAutoRecordCalls($0) }))
                Toggle("Stop WhatsApp and iPhone calls on hang-up", isOn: Binding(
                    get: { state.autoStopCalls }, set: { state.setAutoStopCalls($0) }))
                Toggle("Ask to stop when a meeting ends", isOn: Binding(
                    get: { state.promptOnMeetingEnd }, set: { state.setPromptOnMeetingEnd($0) }))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
    }

    // MARK: – Building blocks

    private func title(_ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            Text(heading).font(Theme.titleFont)
            Text(detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Theme.space4)
    }

    private func choice(_ value: Engine, symbol: String, heading: String, detail: String) -> some View {
        let selected = engine == value
        return Button {
            engine = value
        } label: {
            HStack(alignment: .top, spacing: Theme.space6) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 28)
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
            }
            .padding(Theme.space6)
            .contentShape(.rect)
            .background(.quaternary.opacity(selected ? 0.6 : 0.25),
                        in: .rect(cornerRadius: Theme.radiusMedium))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: – Flow

    private func load() {
        name = appState.userDisplayName
        endpoint = appState.azureSpeechEndpoint
        azureKey = appState.azureSpeechKey
        elevenLabsKey = appState.elevenLabsAPIKey
        language = appState.defaultLanguage
        if appState.selectedModel.isCloud {
            engine = .cloud
        } else if appState.selectedModel == .parakeetV3 {
            localModel = .parakeetV3
        }
        if case .azure = appState.defaultSummaryModel(for: language) { summaryInCloud = true }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        step = next
    }

    private func finish() {
        appState.setUserDisplayName(name)
        appState.setDefaultLanguage(language)
        if engine == .cloud, let cloud = cloudEngine {
            appState.setAzureSpeechEndpoint(endpoint)
            appState.setAzureSpeechKey(azureKey)
            appState.setElevenLabsAPIKey(elevenLabsKey)
            appState.setDefaultEngine(cloud)
        } else {
            appState.setDefaultEngine(localModel)
        }
        appState.completeSetup()
    }
}

/// Download control for the default local summary model.
private struct LocalSummaryModelRow: View {
    let model: LanguageModel
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack {
            Text(model.displayName).font(.callout)
            Spacer()
            switch appState.modelState(for: model) {
            case .notDownloaded:
                Button("Download Now") { appState.downloadModel(model) }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 140)
            case .downloaded:
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(Theme.space6)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: Theme.radiusMedium))
        Text("You can skip this; it downloads when you first summarize, or in Settings › Summary.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Asks for the permissions that can be requested up front. Screen and
/// Automation prompts otherwise appear on the first recording.
private struct PermissionsStep: View {
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space8) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                Text("Permissions").font(Theme.titleFont)
                Text("macOS asks once for each. You can also allow them later, when the app first needs them.")
                    .foregroundStyle(.secondary)
            }
            row("Microphone", "Your side of the meeting.", granted: micGranted) {
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    Task { @MainActor in micGranted = ok }
                }
            }
            row("Screen & System Audio Recording", "The other side of the meeting.", granted: screenGranted) {
                screenGranted = CGRequestScreenCaptureAccess()
            }
            row("Notifications",
                notificationStatus == .denied
                    ? "Turned off in System Settings. Turn them on there to get \"Meeting ended?\"."
                    : "\"Meeting ended?\" and call recording notices.",
                granted: [.authorized, .provisional].contains(notificationStatus),
                buttonTitle: notificationStatus == .denied ? "Open Settings…" : "Allow…") {
                if notificationStatus == .denied, let url = URL(string:
                    "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                } else {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                        Task { @MainActor in await refreshNotifications() }
                    }
                }
            }
            Text("Arc, Safari and Chrome each ask for Automation access when the app first looks for a meeting tab. iPhone calls ask for System Audio Recording on the first call.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await refreshNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotifications() }
            screenGranted = CGPreflightScreenCaptureAccess()
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    private func refreshNotifications() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func row(_ title: String, _ detail: String, granted: Bool,
                     buttonTitle: String = "Allow…",
                     request: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(buttonTitle, action: request)
            }
        }
        .padding(Theme.space6)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: Theme.radiusMedium))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
