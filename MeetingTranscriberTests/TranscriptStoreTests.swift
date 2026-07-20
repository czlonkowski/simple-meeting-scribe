import Foundation
import XCTest
@testable import MeetingTranscriber

final class TranscriptStoreTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTranscriberTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        directoryURL = nil
    }

    func testDecodeAllExcludesTagCatalogSkipsMalformedFilesAndSortsNewestFirst() throws {
        try transcriptJSON(
            id: "older",
            date: "2026-01-01T09:00:00Z"
        ).write(
            to: directoryURL.appendingPathComponent("older.json"),
            atomically: true,
            encoding: .utf8
        )
        try transcriptJSON(
            id: "newer",
            date: "2026-02-01T09:00:00Z"
        ).write(
            to: directoryURL.appendingPathComponent("newer.json"),
            atomically: true,
            encoding: .utf8
        )
        try "[{\"name\":\"Client\",\"color\":\"blue\"}]".write(
            to: directoryURL.appendingPathComponent("tags.json"),
            atomically: true,
            encoding: .utf8
        )
        try "not-json".write(
            to: directoryURL.appendingPathComponent("broken.json"),
            atomically: true,
            encoding: .utf8
        )

        let documents = try TranscriptStore.decodeAll(at: directoryURL)

        XCTAssertEqual(documents.map(\.id), ["newer", "older"])
    }

    func testDecodeAllReturnsEmptyForMissingDirectory() throws {
        let missing = directoryURL.appendingPathComponent("missing", isDirectory: true)
        XCTAssertEqual(try TranscriptStore.decodeAll(at: missing), [])
    }

    private func transcriptJSON(id: String, date: String) -> String {
        """
        {
          "id": "\(id)",
          "title": "\(id)",
          "date": "\(date)",
          "duration": 1,
          "language": "en",
          "modelShortName": "test",
          "sourceKind": "live",
          "speakers": [],
          "segments": []
        }
        """
    }
}
