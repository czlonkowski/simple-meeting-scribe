import Foundation

/// Asks the n8n "meeting lookup" webhook for calendar events around a
/// recording, then picks the one the recording belongs to.
///
/// n8n stays simple: list events between `windowStart` and `windowEnd` and
/// return them. Choosing, filtering declined/all-day events and trimming the
/// description happen here, where they can be tested.
enum MeetingLookup {
    static let timeout: TimeInterval = 8
    /// How far before the recording start events are looked for: people
    /// usually press record a few minutes after the meeting begins.
    static let leadWindow: TimeInterval = 20 * 60
    static let maxDescriptionLength = 800

    // MARK: Request

    struct Request: Encodable, Equatable {
        let schemaVersion: Int
        let event: String
        let transcriptId: String
        let start: Date
        let end: Date
        let windowStart: Date
        let windowEnd: Date
        let durationSec: Double
        let timeZone: String
        let sourceKind: String
        let sourceURL: String?
        let meetCode: String?
        let title: String
        let language: String

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, event, transcriptId, start, end, windowStart, windowEnd,
                 durationSec, timeZone, sourceKind, sourceURL, meetCode, title, language
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schemaVersion, forKey: .schemaVersion)
            try c.encode(event, forKey: .event)
            try c.encode(transcriptId, forKey: .transcriptId)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
            try c.encode(windowStart, forKey: .windowStart)
            try c.encode(windowEnd, forKey: .windowEnd)
            try c.encode(durationSec, forKey: .durationSec)
            try c.encode(timeZone, forKey: .timeZone)
            try c.encode(sourceKind, forKey: .sourceKind)
            try c.encode(sourceURL, forKey: .sourceURL)
            try c.encode(meetCode, forKey: .meetCode)
            try c.encode(title, forKey: .title)
            try c.encode(language, forKey: .language)
        }
    }

    struct Response: Decodable {
        var events: [CalendarEvent]

        private enum CodingKeys: String, CodingKey { case events }

        init(from decoder: Decoder) throws {
            // Accept `{ "events": [...] }` or a bare array.
            if let c = try? decoder.container(keyedBy: CodingKeys.self) {
                events = try c.decodeIfPresent([CalendarEvent].self, forKey: .events) ?? []
            } else {
                events = try decoder.singleValueContainer().decode([CalendarEvent].self)
            }
        }
    }

    /// Nil when the recording's start time is unknown (nothing to look up).
    static func request(for doc: TranscriptDocument, timeZone: TimeZone = .current) -> Request? {
        guard let start = recordingStart(of: doc) else { return nil }
        let end = start.addingTimeInterval(max(doc.duration, 0))
        return Request(schemaVersion: 1, event: "meeting.lookup", transcriptId: doc.id,
                       start: start, end: end,
                       windowStart: start.addingTimeInterval(-leadWindow), windowEnd: end,
                       durationSec: doc.duration, timeZone: timeZone.identifier,
                       sourceKind: doc.sourceKind.rawValue, sourceURL: doc.sourceURL,
                       meetCode: doc.sourceURL.flatMap(meetCode(from:)),
                       title: doc.title, language: doc.language.rawValue)
    }

    /// When the recording began: the stored start, else (live recordings made
    /// before it was stored) the voice stem's `yyyy-MM-dd_HHmmss` name, else
    /// an import's media date.
    static func recordingStart(of doc: TranscriptDocument) -> Date? {
        if let start = doc.recordingStartedAt { return start }
        if doc.sourceKind == .live, let name = doc.audioFileName, let stem = startFromAudioFileName(name) {
            return stem
        }
        return doc.sourceKind == .imported ? doc.recordedAt : nil
    }

    /// Parses `2026-11-08_203243.voice.wav` (local time) into a date.
    static func startFromAudioFileName(_ name: String, timeZone: TimeZone = .current) -> Date? {
        let stem = String(name.prefix(17))   // "yyyy-MM-dd_HHmmss"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.date(from: stem)
    }

    /// The `abc-defg-hij` code of a Google Meet URL, lowercased.
    static func meetCode(from raw: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host()?.lowercased(), host == "meet.google.com" else { return nil }
        let code = url.pathComponents.first { $0 != "/" }?.lowercased() ?? ""
        return code.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil ? code : nil
    }

    // MARK: Choosing the event

    /// Best event for a recording: same Meet link first, then largest overlap,
    /// then the closest start. Skips all-day, cancelled and self-declined
    /// events, and events that neither overlap nor start within the lead window.
    static func select(from events: [CalendarEvent], start: Date, end: Date,
                       meetCode: String?) -> CalendarEvent? {
        let candidates = events.filter { event in
            guard !event.allDay,
                  event.status?.lowercased() != "cancelled",
                  event.selfResponseStatus?.lowercased() != "declined",
                  event.end > event.start else { return false }
            return overlap(event, start, end) > 0
                || abs(event.start.timeIntervalSince(start)) <= leadWindow
        }
        if let meetCode,
           let byLink = candidates.first(where: { ($0.meetingURL ?? "").lowercased().contains(meetCode) }) {
            return byLink
        }
        return candidates.min { a, b in
            let oa = overlap(a, start, end), ob = overlap(b, start, end)
            if oa != ob { return oa > ob }
            return abs(a.start.timeIntervalSince(start)) < abs(b.start.timeIntervalSince(start))
        }
    }

    private static func overlap(_ event: CalendarEvent, _ start: Date, _ end: Date) -> TimeInterval {
        max(0, min(event.end, end).timeIntervalSince(max(event.start, start)))
    }

    /// What gets stored: declined attendees dropped, description trimmed and
    /// stripped of join links, dial-in numbers and PINs.
    static func sanitized(_ event: CalendarEvent) -> CalendarEvent {
        var copy = event
        copy.attendees = event.attendees.filter { !$0.hasDeclined }
        copy.description = event.description.flatMap(cleanDescription)
        return copy
    }

    /// Everything after the first separator line is the meeting app's
    /// invitation boilerplate (Teams "______", Google "-::~:~::~").
    private static let separator = #"^\s*(_{8,}|-{8,}|-::~[:~]+)"#
    /// Lines that carry no meeting context: join links, dial-ins, IDs and
    /// passcodes, help links, mail signatures and inline images.
    private static let noise = #"(?i)(meet\.google\.com|teams\.microsoft|zoom\.us|https?://|www\.|\[cid:|\bjoin\b|dołącz|dial[- ]?in|\bpin\b|passcode|kod dostępu|meeting id|identyfikator spotkania|conference id|tenant key|video id|find a local number|need help|potrzebujesz pomocy|meeting options|opcje spotkania|system reference|odwołanie systemowe|more info|official use only|reschedule or cancel|\+\d[\d\s-]{6,}|^(tel|e|mob|m|t)\s*[.:]|[\w.+-]+@[\w-]+\.[\w.]+|^ul\.\s|^\d{2}-\d{3}\s)"#

    static func cleanDescription(_ raw: String) -> String? {
        let withoutTags = raw
            .replacingOccurrences(of: #"<(br|p|div|li)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        var kept: [String] = []
        for line in withoutTags.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: separator, options: .regularExpression) != nil { break }
            guard !trimmed.isEmpty,
                  trimmed.range(of: noise, options: .regularExpression) == nil,
                  trimmed.rangeOfCharacter(from: .letters) != nil else { continue }
            kept.append(trimmed)
        }
        let text = kept.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return text.count > maxDescriptionLength
            ? String(text.prefix(maxDescriptionLength)) + "…"
            : text
    }

    // MARK: Call

    /// Never throws: failures come back as `.failed` so summarizing carries on.
    static func lookup(_ doc: TranscriptDocument, config: WebhookConfig,
                       session: URLSession? = nil, now: Date = Date()) async -> CalendarLookup {
        guard let request = request(for: doc) else {
            return CalendarLookup(at: now, status: .none, event: nil, error: "Recording start unknown")
        }
        do {
            let body = try WebhookEnvelope.encoder().encode(request)
            let urlRequest = try WebhookClient.request(body: body, config: config, timeout: timeout)
            let data = try await WebhookClient.perform(urlRequest, session: session)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let events = data.isEmpty ? [] : try decoder.decode(Response.self, from: data).events
            let chosen = select(from: events, start: request.start, end: request.end,
                                meetCode: request.meetCode).map(sanitized)
            Log.webhook.notice("lookup: \(doc.id, privacy: .public) \(events.count, privacy: .public) events → \(chosen?.title ?? "no match", privacy: .public)")
            return CalendarLookup(at: now, status: chosen == nil ? .none : .matched, event: chosen)
        } catch {
            Log.webhook.error("lookup failed: \(error.localizedDescription, privacy: .public)")
            return CalendarLookup(at: now, status: .failed, event: nil, error: error.localizedDescription)
        }
    }
}
