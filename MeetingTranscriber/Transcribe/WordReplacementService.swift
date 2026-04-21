import Foundation

/// Case-insensitive post-processing find/replace over transcript text.
/// Mirrors VoiceInk's approach: Whisper's initial prompt is unreliable for
/// custom vocabulary, so we fix misspellings deterministically after decoding.
enum WordReplacementService {

    /// Apply the enabled entries, in order, to `text`.
    /// Each `original` field may be a comma-separated list of variants
    /// ("Max, maks, maxs" → "Mateusz").
    static func apply(_ replacements: [WordReplacement], to text: String) -> String {
        var out = text
        for entry in replacements where entry.isEnabled {
            let variants = entry.original
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let target = entry.replacement
            guard !variants.isEmpty, !target.isEmpty else { continue }

            for variant in variants {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: variant))\\b"
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(out.startIndex..., in: out)
                    out = regex.stringByReplacingMatches(
                        in: out, options: [], range: range, withTemplate: target
                    )
                }
            }
        }
        return out
    }
}
