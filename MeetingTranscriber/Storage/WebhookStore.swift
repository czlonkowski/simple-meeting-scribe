import Foundation

/// The n8n webhook transcripts are sent to. The URL and the header value are
/// secrets (an n8n webhook path works like a token), so both live in the
/// Keychain; the header name is plain config in UserDefaults.
enum WebhookStore {
    private static let urlKey = StoredAPIKey(account: "n8n-webhook-url")
    private static let headerValueKey = StoredAPIKey(account: "n8n-webhook-auth")
    private static let headerNameDefaultsKey = "Webhook.AuthHeaderName"

    static let defaultHeaderName = "Authorization"
    private static let lookupURLKey = StoredAPIKey(account: "n8n-meeting-lookup-url")
    private static let lookupEnabledDefaultsKey = "Webhook.MeetingLookupEnabled"

    /// Meeting lookup webhook (calendar event before summarizing). Shares the
    /// auth header with the export webhook.
    static func loadLookupURL() -> String { lookupURLKey.load() ?? "" }
    static func saveLookupURL(_ value: String) { lookupURLKey.save(value) }
    static func loadLookupEnabled() -> Bool { UserDefaults.standard.bool(forKey: lookupEnabledDefaultsKey) }
    static func saveLookupEnabled(_ value: Bool) { UserDefaults.standard.set(value, forKey: lookupEnabledDefaultsKey) }

    private static let autoSendDefaultsKey = "Webhook.AutoSend"

    /// Send every new transcript once it's ready (after the auto-summary).
    static func loadAutoSend() -> Bool { UserDefaults.standard.bool(forKey: autoSendDefaultsKey) }
    static func saveAutoSend(_ value: Bool) { UserDefaults.standard.set(value, forKey: autoSendDefaultsKey) }

    static func loadURL() -> String { urlKey.load() ?? "" }
    static func saveURL(_ value: String) { urlKey.save(value) }

    static func loadHeaderValue() -> String { headerValueKey.load() ?? "" }
    static func saveHeaderValue(_ value: String) { headerValueKey.save(value) }

    static func loadHeaderName() -> String {
        UserDefaults.standard.string(forKey: headerNameDefaultsKey) ?? defaultHeaderName
    }

    static func saveHeaderName(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines),
                                  forKey: headerNameDefaultsKey)
    }

    /// Parsed webhook URL, or nil when it isn't usable. Only https is allowed,
    /// except plain http to localhost for testing.
    static func validatedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host(), !host.isEmpty else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) { return url }
        return nil
    }
}
