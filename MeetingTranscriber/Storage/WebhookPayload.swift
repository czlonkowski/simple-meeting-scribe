import CryptoKit
import Foundation

/// JSON body POSTed to the n8n webhook (contract `schemaVersion` 1).
///
/// n8n deduplicates on `transcript.id` (upsert) and compares
/// `transcript.contentHash` to skip re-sends with no new content. Treat
/// `segments` as replace-all: re-transcription renumbers speakers.
struct WebhookEnvelope: Encodable, Equatable {
    static let currentSchemaVersion = 1

    enum Event: String, Encodable {
        case transcriptExported = "transcript.exported"
        case ping
    }

    struct App: Encodable, Equatable {
        let name: String
        let version: String
        let bundleID: String
        /// The Mac's time zone, so n8n can show the UTC dates in local time.
        let timeZone: String
    }

    let schemaVersion: Int
    let event: Event
    let sentAt: Date
    let app: App
    let transcript: WebhookTranscript?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, event, sentAt, app, transcript
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(event, forKey: .event)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(app, forKey: .app)
        try c.encode(transcript, forKey: .transcript)   // explicit null for ping
    }

    static func exported(_ doc: TranscriptDocument, sentAt: Date = Date(),
                         app: App = .current) -> WebhookEnvelope {
        WebhookEnvelope(schemaVersion: currentSchemaVersion, event: .transcriptExported,
                        sentAt: sentAt, app: app, transcript: WebhookTranscript(doc))
    }

    static func ping(sentAt: Date = Date(), app: App = .current) -> WebhookEnvelope {
        WebhookEnvelope(schemaVersion: currentSchemaVersion, event: .ping,
                        sentAt: sentAt, app: app, transcript: nil)
    }

    /// Sorted keys, ISO-8601 UTC dates. Used for hashing and for nested values.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The request body. JSONEncoder can't keep field order, so the envelope
    /// and transcript objects are written field by field: metadata and summary
    /// first, the long `segments` array last, so they're readable in n8n.
    func wireData() throws -> Data {
        var object = OrderedJSONObject()
        try object.add("schemaVersion", schemaVersion)
        try object.add("event", event)
        try object.add("sentAt", sentAt)
        try object.add("app", app)
        if let transcript {
            object.addRaw("transcript", try transcript.wireData())
        } else {
            object.addRaw("transcript", Data("null".utf8))
        }
        return object.data
    }
}

/// Writes one JSON object with keys in insertion order; values are encoded
/// with `WebhookEnvelope.encoder()`.
private struct OrderedJSONObject {
    private var parts: [Data] = []
    private let encoder = WebhookEnvelope.encoder()

    mutating func add<T: Encodable>(_ key: String, _ value: T) throws {
        addRaw(key, try encoder.encode(value))
    }

    mutating func addRaw(_ key: String, _ json: Data) {
        var part = (try? encoder.encode(key)) ?? Data()
        part.append(UInt8(ascii: ":"))
        part.append(json)
        parts.append(part)
    }

    var data: Data {
        var out = Data("{".utf8)
        for (index, part) in parts.enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            out.append(part)
        }
        out.append(UInt8(ascii: "}"))
        return out
    }
}

extension WebhookEnvelope.App {
    static var current: Self {
        let info = Bundle.main.infoDictionary ?? [:]
        return Self(name: "meeting-transcriber",
                    version: info["CFBundleShortVersionString"] as? String ?? "unknown",
                    bundleID: Bundle.main.bundleIdentifier ?? "com.czlonkowski.MeetingTranscriber",
                    timeZone: TimeZone.current.identifier)
    }
}

struct WebhookTranscript: Encodable, Equatable {
    struct Speaker: Encodable, Equatable {
        let id: Int
        let name: String
    }

    struct Segment: Encodable, Equatable {
        let start: Double
        let end: Double
        let speakerId: Int
        let speakerName: String
        let text: String
    }

    struct Summary: Encodable, Equatable {
        let markdown: String
        let model: String?
        let generatedAt: Date?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(markdown, forKey: .markdown)
            try c.encode(model, forKey: .model)
            try c.encode(generatedAt, forKey: .generatedAt)
        }

        private enum CodingKeys: String, CodingKey { case markdown, model, generatedAt }
    }

    struct Flags: Encodable, Equatable {
        let partialSystemCapture: Bool
        let speakersCorrected: Bool
    }

    let id: String
    /// "sha256:<hex>" over every field except this one and `markdown`
    /// (markdown is derived, and its long-form dates follow the Mac's locale).
    private(set) var contentHash: String
    let title: String
    let createdAt: Date
    let recordedAt: Date?
    let durationSec: Double
    let language: String
    let engine: String
    let sourceKind: String
    let sourceURL: String?
    let tags: [String]
    let speakers: [Speaker]
    /// Calendar event matched by the meeting lookup, nil when none.
    let calendarEvent: CalendarEvent?
    let segments: [Segment]
    private(set) var markdown: String
    let summary: Summary?
    let flags: Flags

    init(_ doc: TranscriptDocument) { self.init(doc, includeMarkdown: true) }

    private init(_ doc: TranscriptDocument, includeMarkdown: Bool) {
        id = doc.id
        title = doc.title
        createdAt = doc.date
        recordedAt = doc.recordedAt
        durationSec = doc.duration
        language = doc.language.rawValue
        engine = doc.modelShortName
        sourceKind = doc.sourceKind.rawValue
        sourceURL = doc.sourceURL
        tags = doc.tags
        speakers = doc.speakers.map { Speaker(id: $0.id, name: $0.name) }
        calendarEvent = doc.calendarEvent
        let names = Dictionary(doc.speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        segments = doc.segments.map {
            Segment(start: $0.start, end: $0.end, speakerId: $0.speakerId,
                    speakerName: names[$0.speakerId] ?? "Unknown", text: $0.text)
        }
        if let text = doc.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            summary = Summary(markdown: text, model: doc.summaryModelShortName,
                              generatedAt: doc.summaryGeneratedAt)
        } else {
            summary = nil
        }
        flags = Flags(partialSystemCapture: doc.hasPartialSystemCapture,
                      speakersCorrected: doc.speakersCorrectedAt != nil)
        markdown = ""
        contentHash = ""
        contentHash = Self.hash(of: self)
        if includeMarkdown { markdown = TranscriptFormatter.renderMarkdown(doc) }
    }

    /// Content hash of a document, without building the markdown.
    static func contentHash(of doc: TranscriptDocument) -> String {
        WebhookTranscript(doc, includeMarkdown: false).contentHash
    }

    private static func hash(of transcript: WebhookTranscript) -> String {
        var copy = transcript
        copy.contentHash = ""
        copy.markdown = ""
        let data = (try? WebhookEnvelope.encoder().encode(copy)) ?? Data()
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case id, contentHash, title, createdAt, recordedAt, durationSec, language, engine,
             sourceKind, sourceURL, tags, speakers, calendarEvent, segments, markdown, summary, flags
    }

    /// Wire order for n8n; see `WebhookEnvelope.wireData()`.
    func wireData() throws -> Data {
        var o = OrderedJSONObject()
        try o.add("id", id)
        try o.add("contentHash", contentHash)
        try o.add("title", title)
        try o.add("createdAt", createdAt)
        try o.add("recordedAt", recordedAt)
        try o.add("durationSec", durationSec)
        try o.add("language", language)
        try o.add("engine", engine)
        try o.add("sourceKind", sourceKind)
        try o.add("sourceURL", sourceURL)
        try o.add("tags", tags)
        try o.add("flags", flags)
        try o.add("speakers", speakers)
        try o.add("calendarEvent", calendarEvent)
        try o.add("summary", summary)
        try o.add("markdown", markdown)
        try o.add("segments", segments)
        return o.data
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(contentHash, forKey: .contentHash)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(recordedAt, forKey: .recordedAt)
        try c.encode(durationSec, forKey: .durationSec)
        try c.encode(language, forKey: .language)
        try c.encode(engine, forKey: .engine)
        try c.encode(sourceKind, forKey: .sourceKind)
        try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(tags, forKey: .tags)
        try c.encode(flags, forKey: .flags)
        try c.encode(speakers, forKey: .speakers)
        // IfPresent: transcripts without an event keep the hash they had
        // before this field existed.
        try c.encodeIfPresent(calendarEvent, forKey: .calendarEvent)
        try c.encode(summary, forKey: .summary)
        try c.encode(markdown, forKey: .markdown)
        try c.encode(segments, forKey: .segments)
    }
}
