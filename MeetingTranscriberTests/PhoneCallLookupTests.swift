import Foundation
import XCTest
@testable import MeetingTranscriber

final class PhoneCallLookupTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_767_268_800)

    private func record(_ address: String, start: TimeInterval, duration: Double,
                        provider: String? = "com.apple.Telephony") -> PhoneCallLookup.Record {
        .init(address: address, name: nil, originated: false, answered: true,
              date: t0.addingTimeInterval(start), duration: duration, serviceProvider: provider)
    }

    func testPicksCallOverlappingTheRecording() {
        let records = [
            record("+48000000002", start: -3000, duration: 60),   // earlier call
            record("+48000000001", start: -5, duration: 240),     // this one
            record("+48000000003", start: 900, duration: 30),     // later call
        ]
        let pick = PhoneCallLookup.pick(records, start: t0, end: t0.addingTimeInterval(228))
        XCTAssertEqual(pick?.address, "+48000000001")
    }

    func testIgnoresOtherProvidersAndEmptyAddresses() {
        let records = [
            record("opaque-handle", start: 0, duration: 228, provider: "net.whatsapp.WhatsApp"),
            record("", start: 0, duration: 228),
        ]
        XCTAssertNil(PhoneCallLookup.pick(records, start: t0, end: t0.addingTimeInterval(228)))
    }

    func testPrefersLongerOverlap() {
        let records = [
            record("+48000000004", start: -200, duration: 90),   // ends just inside the slack
            record("+48000000001", start: 10, duration: 200),
        ]
        let pick = PhoneCallLookup.pick(records, start: t0, end: t0.addingTimeInterval(228))
        XCTAssertEqual(pick?.address, "+48000000001")
    }

    func testCallStartComesFromDetectorURL() {
        var doc = makeDoc(sourceURL: "call://com.apple.FaceTime/1767268800")
        XCTAssertTrue(PhoneCallLookup.isPhoneCall(doc))
        XCTAssertEqual(PhoneCallLookup.callStart(doc), t0)

        doc.sourceURL = "call://net.whatsapp.WhatsApp/1767268800"
        XCTAssertFalse(PhoneCallLookup.isPhoneCall(doc))
    }

    func testPayloadCarriesPhoneCallOnlyWhenKnown() throws {
        var doc = makeDoc(sourceURL: "call://com.apple.FaceTime/1767268800")
        let before = WebhookTranscript.contentHash(of: doc)
        XCTAssertFalse(String(decoding: try WebhookEnvelope.exported(doc).wireData(), as: UTF8.self)
            .contains("+48000000001"))

        doc.phoneCall = PhoneCallInfo(number: "+48000000001", direction: .incoming,
                                      answered: true, startedAt: t0, durationSec: 228)
        let json = String(decoding: try WebhookEnvelope.exported(doc).wireData(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"phoneCall\":{"))
        XCTAssertTrue(json.contains("+48000000001"))
        XCTAssertNotEqual(WebhookTranscript.contentHash(of: doc), before)
    }

    private func makeDoc(sourceURL: String) -> TranscriptDocument {
        TranscriptDocument(id: "2026-01-01_120000", title: "Phone call", date: t0, duration: 228,
                           language: .polish, modelShortName: "test", sourceURL: sourceURL,
                           sourceKind: .live, speakers: [], segments: [], audioFileName: nil)
    }
}
