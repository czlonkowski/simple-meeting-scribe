import Foundation
import XCTest
@testable import MeetingTranscriber

private final class LookupStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MeetingLookupTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let base = Date(timeIntervalSince1970: 1_762_600_000)   // recording start

    private func event(_ id: String, startOffset: TimeInterval, minutes: Double,
                       meetingURL: String? = nil, allDay: Bool = false,
                       selfResponse: String? = nil, status: String? = nil) -> CalendarEvent {
        let start = base.addingTimeInterval(startOffset)
        return CalendarEvent(id: id, title: id, start: start, end: start.addingTimeInterval(minutes * 60),
                             allDay: allDay, status: status, selfResponseStatus: selfResponse,
                             meetingURL: meetingURL)
    }

    private func liveDoc(duration: TimeInterval = 1800, sourceURL: String? = nil) -> TranscriptDocument {
        TranscriptDocument(id: "2026-11-08_203256", title: "Recording", date: base.addingTimeInterval(duration + 10),
                           duration: duration, language: .polish, modelShortName: "mai-transcribe-2",
                           sourceURL: sourceURL, sourceKind: .live, speakers: [], segments: [],
                           audioFileName: "2026-11-08_203243.voice.wav")
    }

    func testMeetCodeParsing() {
        XCTAssertEqual(MeetingLookup.meetCode(from: "https://meet.google.com/NIT-xjkb-sqq?authuser=0"), "nit-xjkb-sqq")
        XCTAssertNil(MeetingLookup.meetCode(from: "https://meet.google.com/landing"))
        XCTAssertNil(MeetingLookup.meetCode(from: "call://com.apple.FaceTime/123"))
    }

    func testStartFromAudioFileName() {
        let date = MeetingLookup.startFromAudioFileName("2026-11-08_203243.voice.wav", timeZone: utc)
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-11-08T20:32:43Z"))
        XCTAssertNil(MeetingLookup.startFromAudioFileName("imported.m4a"))
    }

    func testRecordingStartPrefersStoredStart() {
        var doc = liveDoc()
        doc.recordingStartedAt = base
        XCTAssertEqual(MeetingLookup.recordingStart(of: doc), base)
        doc.recordingStartedAt = nil
        XCTAssertNotNil(MeetingLookup.recordingStart(of: doc), "falls back to the voice stem name")
    }

    func testSelectPrefersMeetLinkThenOverlap() {
        let end = base.addingTimeInterval(1800)
        let overlapping = event("big-overlap", startOffset: -300, minutes: 60)
        let linked = event("linked", startOffset: 600, minutes: 15, meetingURL: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(MeetingLookup.select(from: [overlapping, linked], start: base, end: end,
                                            meetCode: "abc-defg-hij")?.id, "linked")
        XCTAssertEqual(MeetingLookup.select(from: [linked, overlapping], start: base, end: end,
                                            meetCode: nil)?.id, "big-overlap")
    }

    func testSelectSkipsAllDayDeclinedCancelledAndFarEvents() {
        let end = base.addingTimeInterval(1800)
        let events = [
            event("all-day", startOffset: -3600, minutes: 24 * 60, allDay: true),
            event("declined", startOffset: 0, minutes: 30, selfResponse: "declined"),
            event("cancelled", startOffset: 0, minutes: 30, status: "cancelled"),
            event("yesterday", startOffset: -86_400, minutes: 30)
        ]
        XCTAssertNil(MeetingLookup.select(from: events, start: base, end: end, meetCode: nil))
    }

    func testSelectAcceptsEventStartingJustAfterShortRecording() {
        // A 1-minute test recording 10 minutes before the event still matches.
        let end = base.addingTimeInterval(60)
        let soon = event("soon", startOffset: 600, minutes: 30)
        XCTAssertEqual(MeetingLookup.select(from: [soon], start: base, end: end, meetCode: nil)?.id, "soon")
    }

    func testSanitizedDropsDeclinedAndCleansDescription() {
        var e = event("e", startOffset: 0, minutes: 30)
        e.attendees = [CalendarAttendee(name: "Anna", responseStatus: "accepted"),
                       CalendarAttendee(name: "Piotr", responseStatus: "declined"),
                       CalendarAttendee(email: "konrad@example.com")]
        e.description = "Agenda: oferta<br>Join with Google Meet: https://meet.google.com/abc-defg-hij<br>PIN: 1234\nBudżet 50k"
        let clean = MeetingLookup.sanitized(e)
        XCTAssertEqual(clean.participantNames, ["Anna", "konrad@example.com"])
        XCTAssertEqual(clean.description, "Agenda: oferta\nBudżet 50k")
    }

    func testTeamsInviteAndSignatureAreStripped() {
        let teams = """
        Dzień dobry,

        Zapraszam na spotkanie w ramach konferencji.
        [cid:image001.png@01DD5C95.6F6F98D0]
        Jan Kowalski
        tel.: +48 600 000 000
        e: jan.kowalski@example.com<mailto:jan.kowalski@example.com>
        ul. Przykładowa 1
        00-001 Warszawa
        www.example.com/<http://www.example.com/>
        ________________________________________________________________________________
        Microsoft Teams meeting
        Meeting ID: 228 026 067 306 359
        Need help?
        ________________________________
        Official Use Only
        """
        XCTAssertEqual(MeetingLookup.cleanDescription(teams),
                       "Dzień dobry,\nZapraszam na spotkanie w ramach konferencji.\nJan Kowalski")
        XCTAssertNil(MeetingLookup.cleanDescription("________________\nMicrosoft Teams meeting\nMeeting ID: 1"))
        let meet = "Agenda: budżet<br>-::~:~::~:~:~:~:~:~::~:~::-<br>Join with Google Meet: https://meet.google.com/x"
        XCTAssertEqual(MeetingLookup.cleanDescription(meet), "Agenda: budżet")
    }

    func testAttendeeNamesFromAddresses() {
        XCTAssertEqual(CalendarAttendee(email: "piotr.nowak@example.org").displayName, "Piotr Nowak")
        XCTAssertEqual(CalendarAttendee(email: "pnowak@example.com").displayName, "pnowak@example.com")
        XCTAssertEqual(CalendarAttendee(name: "Ewa Zielińska", email: "ewa.zielinska@example.com").promptLabel,
                       "Ewa Zielińska (ewa.zielinska@example.com)")
        let event = CalendarEvent(id: "e", title: "t", start: Date(), end: Date().addingTimeInterval(60),
                                  attendees: [CalendarAttendee(email: "me@example.com", isSelf: true),
                                              CalendarAttendee(name: "Anna", email: "anna@x.pl")])
        XCTAssertEqual(event.participantPromptLabels, ["Anna (anna@x.pl)"])
    }

    func testIdentifyPromptKeepsNamesUnique() {
        let prompt = SummaryPrompts.identifyInstruction(for: .polish, labels: ["Remote 1"], knownSpeakers: ["Romuald"])
        XCTAssertTrue(prompt.contains("Już zidentyfikowani mówcy: Romuald"))
        XCTAssertTrue(prompt.contains("Romek dla Romualda"))
    }

    func testEventDecodesVariousDateFormats() throws {
        let json = """
        {"events":[
          {"id":"1","title":"Timed","start":"2026-11-08T20:00:00+01:00","end":"2026-11-08T20:30:00.000+01:00",
           "attendees":[{"email":"a@x.pl","self":true,"responseStatus":"accepted"}]},
          {"id":"2","title":"Day","start":"2026-11-08","end":"2026-11-09"}
        ]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try decoder.decode(MeetingLookup.Response.self, from: Data(json.utf8)).events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].start, ISO8601DateFormatter().date(from: "2026-11-08T19:00:00Z"))
        XCTAssertEqual(events[0].attendees.first?.isSelf, true)
        XCTAssertFalse(events[0].allDay)
        XCTAssertTrue(events[1].allDay)
    }

    func testBareArrayResponse() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try decoder.decode(MeetingLookup.Response.self,
                                        from: Data(#"[{"id":"1","title":"A","start":"2026-11-08T20:00:00Z","end":"2026-11-08T21:00:00Z"}]"#.utf8)).events
        XCTAssertEqual(events.map(\.id), ["1"])
    }

    func testStoredLookupRoundTrips() throws {
        var doc = liveDoc()
        doc.calendarLookup = CalendarLookup(at: base, status: .matched,
                                            event: event("e", startOffset: 0, minutes: 30))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(TranscriptDocument.self, from: encoder.encode(doc))
        XCTAssertEqual(back.calendarEvent?.id, "e")
    }

    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [LookupStub.self]
        return URLSession(configuration: c)
    }

    private let config = WebhookConfig(url: "https://n8n.example.com/webhook/lookup",
                                       headerName: "Authorization", headerValue: "x")

    func testLookupMatchesAndSendsWindow() async throws {
        var doc = liveDoc(sourceURL: "https://meet.google.com/abc-defg-hij")
        doc.recordingStartedAt = base
        let start = ISO8601DateFormatter().string(from: base.addingTimeInterval(-120))
        let end = ISO8601DateFormatter().string(from: base.addingTimeInterval(3600))
        LookupStub.status = 200
        LookupStub.body = Data(#"{"events":[{"id":"9","title":"Oferta X","start":"\#(start)","end":"\#(end)"}]}"#.utf8)

        let result = await MeetingLookup.lookup(doc, config: config, session: session())
        XCTAssertEqual(result.status, .matched)
        XCTAssertEqual(result.event?.title, "Oferta X")

        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(LookupStub.lastBody)) as? [String: Any])
        XCTAssertEqual(sent["event"] as? String, "meeting.lookup")
        XCTAssertEqual(sent["meetCode"] as? String, "abc-defg-hij")
        XCTAssertEqual(sent["windowStart"] as? String,
                       ISO8601DateFormatter().string(from: base.addingTimeInterval(-MeetingLookup.leadWindow)))
    }

    func testLookupNoneAndFailed() async {
        var doc = liveDoc()
        doc.recordingStartedAt = base
        LookupStub.status = 200
        LookupStub.body = Data(#"{"events":[]}"#.utf8)
        let none = await MeetingLookup.lookup(doc, config: config, session: session())
        XCTAssertEqual(none.status, .none)

        LookupStub.status = 500
        LookupStub.body = Data("boom".utf8)
        let failed = await MeetingLookup.lookup(doc, config: config, session: session())
        XCTAssertEqual(failed.status, .failed)
    }

    func testPromptBlocks() {
        var e = event("Weekly sync", startOffset: 0, minutes: 30)
        e.recurringEventId = "r1"
        e.attendees = [CalendarAttendee(name: "Anna"), CalendarAttendee(name: "Konrad")]
        let participants = CalendarPrompts.participantsBlock(for: .polish, event: e, labelCount: 1)
        XCTAssertTrue(participants?.contains("- Anna") == true)
        XCTAssertTrue(participants?.contains("2 innych uczestnika") == true)
        XCTAssertTrue(CalendarPrompts.contextBlock(for: .english, event: e, timeZone: utc).contains("Invited: Anna, Konrad"))
        XCTAssertTrue(CalendarPrompts.titleHint(for: .english, event: e).contains("recurring"))
    }

    func testExportIncludesEventAndKeepsHashWithoutOne() throws {
        let doc = liveDoc()
        let hashWithout = WebhookTranscript.contentHash(of: doc)
        var withEvent = doc
        withEvent.calendarLookup = CalendarLookup(at: base, status: .matched,
                                                  event: event("e", startOffset: 0, minutes: 30))
        XCTAssertNotEqual(WebhookTranscript.contentHash(of: withEvent), hashWithout)

        var failed = doc
        failed.calendarLookup = CalendarLookup(at: base, status: .failed, event: nil)
        XCTAssertEqual(WebhookTranscript.contentHash(of: failed), hashWithout)

        let data = try WebhookEnvelope.exported(withEvent).wireData()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let t = try XCTUnwrap(root["transcript"] as? [String: Any])
        XCTAssertEqual((t["calendarEvent"] as? [String: Any])?["id"] as? String, "e")
    }
}
