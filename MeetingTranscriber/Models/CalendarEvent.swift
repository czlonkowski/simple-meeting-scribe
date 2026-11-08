import Foundation

/// One attendee of a calendar event, as returned by the n8n meeting lookup.
struct CalendarAttendee: Codable, Hashable, Sendable {
    var name: String?
    var email: String?
    /// Google Calendar values: accepted, declined, tentative, needsAction.
    var responseStatus: String?
    /// True for the calendar owner (the app's user).
    var isSelf: Bool?
    var organizer: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, email, responseStatus, organizer
        case isSelf = "self"
    }

    /// Display name. Without one, a `first.last@` address becomes
    /// "First Last"; any other address is shown as is.
    var displayName: String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else { return nil }
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let parts = local.split(whereSeparator: { ".-_".contains($0) }).filter { $0.count > 1 }
        guard parts.count >= 2 else { return email }
        return parts.map { String($0).capitalized }.joined(separator: " ")
    }

    /// For prompts: "Name (email)", so the model sees the company domain and
    /// can tell two people with the same first name apart.
    var promptLabel: String? {
        guard let display = displayName else { return nil }
        guard let email, !email.isEmpty, display != email else { return display }
        return "\(display) (\(email))"
    }

    var hasDeclined: Bool { responseStatus?.lowercased() == "declined" }
}

/// The calendar event matched to a recording.
struct CalendarEvent: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool = false
    var recurringEventId: String? = nil
    /// Google Calendar values: confirmed, tentative, cancelled.
    var status: String? = nil
    /// The user's own response, e.g. "declined".
    var selfResponseStatus: String? = nil
    var organizer: CalendarAttendee? = nil
    var attendees: [CalendarAttendee] = []
    var description: String? = nil
    var location: String? = nil
    var meetingURL: String? = nil

    var isRecurring: Bool { !(recurringEventId ?? "").isEmpty }

    /// Attendees who didn't decline, with a usable name.
    var participantNames: [String] {
        var seen = Set<String>()
        return attendees
            .filter { !$0.hasDeclined }
            .compactMap(\.displayName)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Attendees who didn't decline, labelled for the LLM; the user's own
    /// entry is left out (they are already named in the transcript).
    var participantPromptLabels: [String] {
        var seen = Set<String>()
        return attendees
            .filter { !$0.hasDeclined && $0.isSelf != true }
            .compactMap(\.promptLabel)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, start, end, allDay, recurringEventId, status, selfResponseStatus,
             organizer, attendees, description, location, meetingURL
    }

    init(id: String, title: String, start: Date, end: Date, allDay: Bool = false,
         recurringEventId: String? = nil, status: String? = nil, selfResponseStatus: String? = nil,
         organizer: CalendarAttendee? = nil, attendees: [CalendarAttendee] = [],
         description: String? = nil, location: String? = nil, meetingURL: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.recurringEventId = recurringEventId
        self.status = status
        self.selfResponseStatus = selfResponseStatus
        self.organizer = organizer
        self.attendees = attendees
        self.description = description
        self.location = location
        self.meetingURL = meetingURL
    }

    /// Lenient: n8n may send dates with or without fractional seconds or an
    /// offset, or a bare `yyyy-MM-dd` for all-day events (which sets `allDay`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        let (startDate, startIsDay) = try Self.decodeDate(c, .start)
        let (endDate, endIsDay) = try Self.decodeDate(c, .end)
        start = startDate
        end = endDate
        allDay = (try? c.decodeIfPresent(Bool.self, forKey: .allDay)) ?? (startIsDay || endIsDay)
        recurringEventId = try? c.decodeIfPresent(String.self, forKey: .recurringEventId)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        selfResponseStatus = try? c.decodeIfPresent(String.self, forKey: .selfResponseStatus)
        organizer = try? c.decodeIfPresent(CalendarAttendee.self, forKey: .organizer)
        attendees = (try? c.decodeIfPresent([CalendarAttendee].self, forKey: .attendees)) ?? []
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        location = try? c.decodeIfPresent(String.self, forKey: .location)
        meetingURL = try? c.decodeIfPresent(String.self, forKey: .meetingURL)
    }

    private static func decodeDate(_ c: KeyedDecodingContainer<CodingKeys>,
                                   _ key: CodingKeys) throws -> (Date, isDayOnly: Bool) {
        if let date = try? c.decode(Date.self, forKey: key) { return (date, false) }
        let raw = try c.decode(String.self, forKey: key)
        guard let parsed = parseDate(raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                   debugDescription: "Unrecognised date \(raw)")
        }
        return parsed
    }

    static func parseDate(_ raw: String) -> (Date, isDayOnly: Bool)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: s) { return (d, false) }
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: s) { return (d, false) }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        if let d = day.date(from: s) { return (d, true) }
        return nil
    }
}

/// Result of asking n8n which calendar event a recording belongs to.
struct CalendarLookup: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        /// An event was found and chosen.
        case matched
        /// n8n answered, but no event fits the recording.
        case none
        /// The webhook couldn't be reached or answered badly; retried next run.
        case failed
    }

    var at: Date
    var status: Status
    var event: CalendarEvent?
    var error: String? = nil
}
