import Foundation
import os

/// Category-scoped loggers. Use these instead of `NSLog` so messages show up
/// unredacted when you filter with
/// `log stream --predicate 'subsystem == "com.czlonkowski.MeetingTranscriber"'`.
///
/// When logging dynamic values use `\(value, privacy: .public)` — otherwise
/// macOS will still mask the arg as `<private>` even with this helper.
enum Log {
    static let subsystem = "com.czlonkowski.MeetingTranscriber"

    static let pipeline      = Logger(subsystem: subsystem, category: "pipeline")
    static let whisper       = Logger(subsystem: subsystem, category: "whisper")
    static let recorder      = Logger(subsystem: subsystem, category: "recorder")
    static let systemAudio   = Logger(subsystem: subsystem, category: "systemAudio")
    static let summary       = Logger(subsystem: subsystem, category: "summary")
}
