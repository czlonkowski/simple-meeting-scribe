import Foundation
import SQLite3

/// Finds the phone number of a recorded iPhone call in the macOS call history
/// (`~/Library/Application Support/CallHistoryDB/CallHistory.storedata`).
///
/// Continuity calls are logged on the Mac as they happen. The database is
/// protected by TCC, so the app needs Full Disk Access; without it the lookup
/// returns nil and is tried again on the next send. The file is an
/// undocumented Core Data store, so columns are read by name and a missing
/// one only drops that value.
enum PhoneCallLookup {
    /// One row of `ZCALLRECORD`.
    struct Record: Equatable {
        var address: String
        var name: String?
        var originated: Bool
        var answered: Bool
        var date: Date
        var duration: Double
        var serviceProvider: String?
    }

    static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CallHistoryDB/CallHistory.storedata")

    /// Slack around the recording when matching a call: the call starts a few
    /// seconds before the detector fires, and recording may stop a bit late.
    static let slack: TimeInterval = 120

    /// Providers that are iPhone or FaceTime calls (other CallKit apps log
    /// opaque handles, not numbers).
    static let phoneProviders: Set<String> = ["com.apple.Telephony", "com.apple.FaceTime"]

    /// Whether the transcript is an iPhone/FaceTime call from `CallDetector`.
    static func isPhoneCall(_ doc: TranscriptDocument) -> Bool {
        doc.sourceKind == .live && (doc.sourceURL ?? "").hasPrefix("call://com.apple.FaceTime/")
    }

    /// Call start from the detector URL `call://<bundle>/<unix seconds>`,
    /// else when the recording began.
    static func callStart(_ doc: TranscriptDocument) -> Date? {
        if let last = doc.sourceURL?.split(separator: "/").last, let seconds = TimeInterval(last) {
            return Date(timeIntervalSince1970: seconds)
        }
        return doc.recordingStartedAt
    }

    /// Read the call history and return the call this transcript recorded.
    static func lookup(for doc: TranscriptDocument) -> PhoneCallInfo? {
        guard isPhoneCall(doc), let start = callStart(doc) else { return nil }
        let end = start.addingTimeInterval(max(doc.duration, 1))
        let records: [Record]
        do {
            records = try readRecords(from: start.addingTimeInterval(-slack - 3600),
                                      to: end.addingTimeInterval(slack))
        } catch {
            Log.webhook.error("call history: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let record = pick(records, start: start, end: end) else {
            Log.webhook.notice("call history: no call matches \(doc.id, privacy: .public)")
            return nil
        }
        return PhoneCallInfo(number: record.address, name: record.name,
                             direction: record.originated ? .outgoing : .incoming,
                             answered: record.answered, startedAt: record.date,
                             durationSec: record.duration)
    }

    /// The phone call that overlaps the recording the most; ties go to the
    /// call that started closest to the recording.
    static func pick(_ records: [Record], start: Date, end: Date) -> Record? {
        let windowStart = start.addingTimeInterval(-slack)
        let windowEnd = end.addingTimeInterval(slack)
        func overlap(_ r: Record) -> TimeInterval {
            let callEnd = r.date.addingTimeInterval(max(r.duration, 1))
            return min(callEnd, windowEnd).timeIntervalSince(max(r.date, windowStart))
        }
        return records
            .filter { !$0.address.isEmpty }
            .filter { $0.serviceProvider.map(phoneProviders.contains) ?? true }
            .filter { overlap($0) > 0 }
            .max { a, b in
                let oa = overlap(a), ob = overlap(b)
                if oa != ob { return oa < ob }
                return abs(a.date.timeIntervalSince(start)) > abs(b.date.timeIntervalSince(start))
            }
    }

    enum LookupError: LocalizedError {
        case noAccess
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .noAccess: "no access to the call history (grant Full Disk Access)"
            case .sqlite(let message): message
            }
        }
    }

    /// Rows with `ZDATE` in the range. Reads a temporary copy of the store
    /// and its WAL so the live database is never opened or locked.
    static func readRecords(from: Date, to: Date, databaseURL: URL = databaseURL) throws -> [Record] {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: databaseURL.path) else { throw LookupError.noAccess }
        let dir = fm.temporaryDirectory.appendingPathComponent("callhistory-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(databaseURL.lastPathComponent)
        do {
            try fm.copyItem(at: databaseURL, to: copy)
        } catch {
            throw LookupError.noAccess
        }
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            if fm.fileExists(atPath: source.path) {
                try? fm.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw LookupError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT * FROM ZCALLRECORD WHERE ZDATE BETWEEN ? AND ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LookupError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSinceReferenceDate)
        sqlite3_bind_double(statement, 2, to.timeIntervalSinceReferenceDate)

        var columns: [String: Int32] = [:]
        for i in 0..<sqlite3_column_count(statement) {
            columns[String(cString: sqlite3_column_name(statement, i))] = i
        }
        func text(_ name: String) -> String? {
            guard let i = columns[name], sqlite3_column_type(statement, i) != SQLITE_NULL,
                  let bytes = sqlite3_column_blob(statement, i) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, i)))
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return value.isEmpty ? nil : value
        }
        func number(_ name: String) -> Double {
            guard let i = columns[name] else { return 0 }
            return sqlite3_column_double(statement, i)
        }

        var records: [Record] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(Record(
                address: text("ZADDRESS") ?? "",
                name: text("ZNAME"),
                originated: number("ZORIGINATED") != 0,
                answered: number("ZANSWERED") != 0,
                date: Date(timeIntervalSinceReferenceDate: number("ZDATE")),
                duration: number("ZDURATION"),
                serviceProvider: text("ZSERVICE_PROVIDER")
            ))
        }
        return records
    }
}
