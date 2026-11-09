import Foundation

/// The other side of an iPhone call recorded on this Mac, read from the
/// macOS call history. Sent to n8n so it can find the person by phone number.
struct PhoneCallInfo: Codable, Hashable, Sendable {
    enum Direction: String, Codable, Sendable {
        case incoming
        case outgoing
    }

    /// Number as the call history stores it, e.g. "+48000000001".
    var number: String
    /// Name the call history cached for the number, if any.
    var name: String? = nil
    var direction: Direction
    var answered: Bool
    var startedAt: Date
    var durationSec: Double
}
