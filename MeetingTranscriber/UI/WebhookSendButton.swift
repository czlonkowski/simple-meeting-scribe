import SwiftUI

/// "Send to n8n" in the transcript's bottom bar. Its own view so the content
/// hash is only recomputed when the document changes, not on every render of
/// the detail view.
struct WebhookSendButton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    let doc: TranscriptDocument

    private enum Status {
        case notConfigured, sending, unsent, sent(Date), changed(Date)
    }

    private var status: Status {
        if appState.webhookSendingIDs.contains(doc.id) { return .sending }
        guard appState.webhookConfig.isConfigured else { return .notConfigured }
        guard let sentAt = doc.webhookSentAt, let sentHash = doc.webhookContentHash else { return .unsent }
        return sentHash == WebhookTranscript.contentHash(of: doc) ? .sent(sentAt) : .changed(sentAt)
    }

    var body: some View {
        let status = status
        Button {
            if case .notConfigured = status {
                openSettings()
            } else {
                Task { await appState.sendToWebhook(documentID: doc.id) }
            }
        } label: {
            Group {
                if case .sending = status {
                    HStack(spacing: Theme.space3) {
                        ProgressView().controlSize(.small)
                        Text("Sending…")
                    }
                } else {
                    Label(title(for: status), systemImage: symbol(for: status))
                }
            }
            .padding(.horizontal, Theme.space4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(isSent(status) ? .green : Theme.accent)
        .disabled(isSending(status))
        .sensoryFeedback(.success, trigger: doc.webhookSentAt)
        .help(help(for: status))
        .accessibilityLabel(title(for: status))
    }

    private func title(for status: Status) -> String {
        switch status {
        case .notConfigured: return "Set up n8n…"
        case .sending:       return "Sending to n8n"
        case .unsent:        return "Send to n8n"
        case .sent:          return "Sent to n8n"
        case .changed:       return "Send update to n8n"
        }
    }

    private func symbol(for status: Status) -> String {
        switch status {
        case .notConfigured:  return "gearshape"
        case .sending, .unsent: return "paperplane.fill"
        case .sent:           return "checkmark.circle.fill"
        case .changed:        return "arrow.triangle.2.circlepath"
        }
    }

    private func help(for status: Status) -> String {
        switch status {
        case .notConfigured:
            return "Add a webhook in Settings → Integrations"
        case .sending:
            return "Sending the transcript to the webhook"
        case .unsent:
            return "Send the transcript, metadata, tags and summary to the n8n webhook"
        case .sent(let date):
            return "Sent \(date.formatted(date: .abbreviated, time: .shortened)). Click to send again."
        case .changed(let date):
            return "Changed since it was sent \(date.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private func isSent(_ status: Status) -> Bool {
        if case .sent = status { return true }
        return false
    }

    private func isSending(_ status: Status) -> Bool {
        if case .sending = status { return true }
        return false
    }
}
