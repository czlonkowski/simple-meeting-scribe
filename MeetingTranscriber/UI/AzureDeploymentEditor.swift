import SwiftUI

/// Add/edit sheet for one Azure OpenAI deployment (Settings → Summary).
/// Changes apply only on Save; Test sends a tiny request with the values as
/// typed, before saving.
struct AzureDeploymentEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: AzureDeployment
    @State private var apiKey: String = ""
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case running
        case passed(String)
        case failed(String)
    }

    init(deployment: AzureDeployment) {
        _draft = State(initialValue: deployment)
    }

    private var isNew: Bool {
        appState.azureDeployment(id: draft.id) == nil
    }

    private var hasStoredKey: Bool {
        appState.hasAzureAPIKey(endpoint: draft.endpoint)
    }

    private var endpointIsValid: Bool {
        draft.chatCompletionsURL != nil
    }

    private var canSave: Bool {
        endpointIsValid
            && !draft.deployment.trimmingCharacters(in: .whitespaces).isEmpty
            && (hasStoredKey || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Endpoint", text: $draft.endpoint,
                              prompt: Text(verbatim: "https://<resource>.openai.azure.com/"))
                    TextField("Deployment", text: $draft.deployment,
                              prompt: Text(verbatim: "gpt54"))
                    TextField("Display name", text: $draft.name, prompt: Text("Optional"))
                    SecureField("API key", text: $apiKey,
                                prompt: Text(hasStoredKey ? "Saved for this resource" : "Required"))
                    Picker("Reasoning effort", selection: $draft.reasoningEffort) {
                        ForEach(AzureDeployment.ReasoningEffort.allCases) { effort in
                            Text(effort.displayName).tag(effort)
                        }
                    }
                    if !draft.endpoint.isEmpty && !endpointIsValid {
                        Label("The endpoint must be an https URL.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                } header: {
                    Text(isNew ? "Add Azure Deployment" : "Edit Azure Deployment")
                        .font(Theme.sectionTitleFont)
                } footer: {
                    Text("Endpoint and key come from the Azure portal → your resource → Keys and Endpoint; a deployment's Target URI works too. Deployment is the deployment name, not the model name. Deployments on the same resource share one key. Choose Model default for models without reasoning (e.g. gpt-4.1), which reject the setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: Theme.space4) {
                Button("Test") { runTest() }
                    .disabled(!canSave || testState == .running)
                testStatus
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    appState.saveAzureDeployment(draft, apiKey: apiKey)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(Theme.space8)
        }
        .frame(width: 540)
        .onChange(of: draft) { testState = .idle }
        .onChange(of: apiKey) { testState = .idle }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .passed(let reply):
            Label("Works — replied “\(reply.prefix(40))”", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .lineLimit(1)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .lineLimit(3)
                .help(message)
        }
    }

    private func runTest() {
        testState = .running
        let deployment = draft
        let key = apiKey
        Task {
            do {
                let reply = try await appState.testAzureDeployment(deployment, apiKey: key)
                testState = .passed(reply)
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
