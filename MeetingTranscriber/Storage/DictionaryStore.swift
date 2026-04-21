import Foundation

/// Persists user dictionary settings:
///   • per-language "prime" text that seeds Whisper's decoder, styling
///     punctuation/diacritics and nudging toward expected vocabulary.
///   • word-replacement pairs applied to every transcript segment after decoding.
enum DictionaryStore {
    private static let primesKey       = "Dictionary.LanguagePrompts"
    private static let replacementsKey = "Dictionary.WordReplacements"

    /// Light greeting sentences style-prime Whisper for punctuation/casing
    /// and (for Polish) diacritics. Pattern taken from VoiceInk.
    static let defaultPrimes: [String: String] = [
        "en": "Hello, how are you doing? Nice to meet you.",
        "pl": "Cześć, jak się masz? Miło cię poznać."
    ]

    static func loadPrimes() -> [String: String] {
        guard
            let data = UserDefaults.standard.data(forKey: primesKey),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return defaultPrimes }
        // Fill in missing languages with defaults.
        var merged = defaultPrimes
        for (k, v) in decoded { merged[k] = v }
        return merged
    }

    static func savePrimes(_ primes: [String: String]) {
        if let data = try? JSONEncoder().encode(primes) {
            UserDefaults.standard.set(data, forKey: primesKey)
        }
    }

    static func loadReplacements() -> [WordReplacement] {
        guard
            let data = UserDefaults.standard.data(forKey: replacementsKey),
            let decoded = try? JSONDecoder().decode([WordReplacement].self, from: data)
        else { return [] }
        return decoded
    }

    static func saveReplacements(_ list: [WordReplacement]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: replacementsKey)
        }
    }
}
