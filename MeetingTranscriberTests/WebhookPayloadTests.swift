import Foundation
import XCTest
@testable import MeetingTranscriber

final class WebhookPayloadTests: XCTestCase {
    private let app = WebhookEnvelope.App(name: "meeting-transcriber", version: "9.9",
                                          bundleID: "test", timeZone: "Europe/Warsaw")

    private func makeDoc() -> TranscriptDocument {
        var doc = TranscriptDocument(
            id: "2026-11-08_101500",
            title: "Weekly sync",
            date: Date(timeIntervalSince1970: 1_762_600_000),
            duration: 125.5,
            language: .polish,
            modelShortName: "mai-transcribe-2",
            sourceURL: "https://meet.google.com/abc-defg-hij",
            sourceKind: .live,
            tags: ["Klient X"],
            speakers: [SpeakerLabel(id: 0, name: "Romuald"), SpeakerLabel(id: 1, name: "Anna")],
            segments: [
                TranscriptSegment(start: 0, end: 2.5, speakerId: 0, text: "Cześć"),
                TranscriptSegment(start: 2.5, end: 5, speakerId: 1, text: "Hej"),
                TranscriptSegment(start: 5, end: 6, speakerId: 7, text: "?")
            ],
            audioFileName: "x.voice.wav"
        )
        doc.summary = "  Krótko.  "
        doc.summaryModelShortName = "gpt61terra"
        doc.summaryGeneratedAt = Date(timeIntervalSince1970: 1_762_600_500)
        return doc
    }

    private func json(_ envelope: WebhookEnvelope) throws -> [String: Any] {
        let data = try envelope.wireData()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testExportedEnvelopeMapsFields() throws {
        let sentAt = Date(timeIntervalSince1970: 1_762_601_000)
        let root = try json(.exported(makeDoc(), sentAt: sentAt, app: app))

        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        XCTAssertEqual(root["event"] as? String, "transcript.exported")
        XCTAssertEqual(root["sentAt"] as? String, "2025-11-08T11:23:20Z")

        let t = try XCTUnwrap(root["transcript"] as? [String: Any])
        XCTAssertEqual(t["id"] as? String, "2026-11-08_101500")
        XCTAssertTrue((t["contentHash"] as? String)?.hasPrefix("sha256:") == true)
        XCTAssertEqual(t["language"] as? String, "pl")
        XCTAssertEqual(t["engine"] as? String, "mai-transcribe-2")
        XCTAssertEqual(t["sourceKind"] as? String, "live")
        XCTAssertEqual(t["tags"] as? [String], ["Klient X"])
        XCTAssertTrue(t["recordedAt"] is NSNull, "absent dates are explicit nulls")
        XCTAssertEqual(t["durationSec"] as? Double, 125.5)

        let segments = try XCTUnwrap(t["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.map { $0["speakerName"] as? String }, ["Romuald", "Anna", "Unknown"])

        let summary = try XCTUnwrap(t["summary"] as? [String: Any])
        XCTAssertEqual(summary["markdown"] as? String, "Krótko.")
        XCTAssertEqual(summary["model"] as? String, "gpt61terra")

        XCTAssertTrue((t["markdown"] as? String)?.contains("**Romuald**: Cześć") == true)
        let flags = try XCTUnwrap(t["flags"] as? [String: Any])
        XCTAssertEqual(flags["speakersCorrected"] as? Bool, false)
    }

    func testWireOrderPutsSummaryBeforeSegments() throws {
        let data = try WebhookEnvelope.exported(makeDoc(), app: app).wireData()
        let text = String(decoding: data, as: UTF8.self)
        let order = try ["\"id\"", "\"title\"", "\"tags\"", "\"summary\"", "\"markdown\"", "\"segments\""]
            .map { try XCTUnwrap(text.range(of: $0)).lowerBound }
        XCTAssertEqual(order, order.sorted())
    }

    func testPingHasNullTranscript() throws {
        let root = try json(.ping(app: app))
        XCTAssertEqual(root["event"] as? String, "ping")
        XCTAssertTrue(root["transcript"] is NSNull)
    }

    func testEmptySummaryIsNull() throws {
        var doc = makeDoc()
        doc.summary = "   "
        let t = try XCTUnwrap(try json(.exported(doc, app: app))["transcript"] as? [String: Any])
        XCTAssertTrue(t["summary"] is NSNull)
    }

    func testContentHashIsStableAndMatchesPayload() {
        let doc = makeDoc()
        let hash = WebhookTranscript.contentHash(of: doc)
        XCTAssertEqual(hash, WebhookTranscript.contentHash(of: doc))
        XCTAssertEqual(hash, WebhookEnvelope.exported(doc, app: app).transcript?.contentHash)
    }

    func testContentHashIgnoresSendStateAndSentAt() {
        let doc = makeDoc()
        var sent = doc
        sent.webhookSentAt = Date()
        sent.webhookContentHash = "sha256:old"
        XCTAssertEqual(WebhookTranscript.contentHash(of: doc), WebhookTranscript.contentHash(of: sent))
        XCTAssertEqual(
            WebhookEnvelope.exported(doc, sentAt: Date(timeIntervalSince1970: 1), app: app).transcript,
            WebhookEnvelope.exported(doc, sentAt: Date(timeIntervalSince1970: 2), app: app).transcript
        )
    }

    func testContentHashChangesWithContent() {
        let base = WebhookTranscript.contentHash(of: makeDoc())

        var retitled = makeDoc(); retitled.title = "Other"
        var retagged = makeDoc(); retagged.tags = []
        var resummarized = makeDoc(); resummarized.summary = "Inne"
        var renamed = makeDoc(); renamed.speakers[1].name = "Ania"

        for doc in [retitled, retagged, resummarized, renamed] {
            XCTAssertNotEqual(WebhookTranscript.contentHash(of: doc), base)
        }
    }

    func testDocumentDecodesWithoutAndWithWebhookFields() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var doc = makeDoc()
        doc.systemAudioSilentFraction = 0.4
        let plain = try decoder.decode(TranscriptDocument.self, from: encoder.encode(doc))
        XCTAssertNil(plain.webhookSentAt)
        XCTAssertNil(plain.webhookContentHash)
        XCTAssertEqual(plain.systemAudioSilentFraction, 0.4)

        doc.webhookSentAt = Date(timeIntervalSince1970: 1_762_602_000)
        doc.webhookContentHash = "sha256:abc"
        let roundTrip = try decoder.decode(TranscriptDocument.self, from: encoder.encode(doc))
        XCTAssertEqual(roundTrip.webhookSentAt, doc.webhookSentAt)
        XCTAssertEqual(roundTrip.webhookContentHash, "sha256:abc")
    }
}
