import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Same enum-with-statics shape as
/// the other stores, but backed by the Security framework instead of
/// UserDefaults — API keys don't belong in a plaintext plist.
enum KeychainHelper {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query as CFDictionary,
                          [kSecValueData as String: data] as CFDictionary)
        }
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// ElevenLabs Scribe credentials.
enum ScribeStore {
    private static let service = "com.czlonkowski.MeetingTranscriber"
    private static let account = "elevenlabs-api-key"

    /// Returns nil when no key is configured.
    static func loadAPIKey() -> String? {
        guard let key = KeychainHelper.read(service: service, account: account),
              !key.isEmpty else { return nil }
        return key
    }

    /// Empty (after trimming) removes the stored key.
    static func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(service: service, account: account)
        } else {
            KeychainHelper.save(trimmed, service: service, account: account)
        }
    }
}
