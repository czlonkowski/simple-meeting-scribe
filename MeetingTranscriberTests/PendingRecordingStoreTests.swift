import XCTest
@testable import MeetingTranscriber

final class PendingRecordingStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingRecordingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testScanFindsUnreferencedLiveRecordingsNewestFirst() throws {
        try makeStem("2026-01-02_090000.voice.wav", seconds: 10)
        try makeStem("2026-01-02_090000.system.wav", seconds: 10)
        try makeStem("2026-01-02_090000.video.mp4", seconds: 1)
        try makeStem("2026-01-03_100000.voice.wav", seconds: 5)
        try makeStem("2026-01-01_080000.voice.wav", seconds: 5)        // transcribed

        let pending = PendingRecordingStore.scan(
            recordingsDir: dir,
            referencedVoiceFiles: ["2026-01-01_080000.voice.wav"]
        )

        XCTAssertEqual(pending.map(\.id), ["2026-01-03_100000", "2026-01-02_090000"])
        let withExtras = pending[1]
        XCTAssertEqual(withExtras.systemFileName, "2026-01-02_090000.system.wav")
        XCTAssertEqual(withExtras.videoFileName, "2026-01-02_090000.video.mp4")
        XCTAssertEqual(withExtras.estimatedDuration, 10, accuracy: 0.01)
        XCTAssertNil(pending[0].systemFileName)
    }

    func testScanSkipsImportsSystemOnlyAndTinyStems() throws {
        try makeStem("import_1790000000_call.wav", seconds: 30)
        try makeStem("2026-01-02_090000.system.wav", seconds: 30)
        try makeStem("2026-01-04_110000.voice.wav", seconds: 0)         // header only
        try makeStem("notes.voice.wav", seconds: 30)                    // not a live name

        XCTAssertTrue(PendingRecordingStore.scan(recordingsDir: dir, referencedVoiceFiles: []).isEmpty)
    }

    func testSidecarRoundTripsAndRestoresMeeting() throws {
        let voice = dir.appendingPathComponent("2026-01-02_090000.voice.wav")
        try makeStem(voice.lastPathComponent, seconds: 5)
        let start = Date(timeIntervalSince1970: 1_767_344_400)
        PendingRecordingStore.writeSidecar(RecordingSidecar(
            title: "Weekly sync",
            language: .english,
            startedAt: start,
            meetingTitle: "Weekly sync",
            meetingPlatform: "Google Meet",
            meetingURL: "https://meet.google.com/abc-defg-hij"
        ), forVoiceURL: voice)
        PendingRecordingStore.updateSidecar(forVoiceURL: voice) { $0.lastError = "Upload failed" }

        let pending = try XCTUnwrap(
            PendingRecordingStore.scan(recordingsDir: dir, referencedVoiceFiles: []).first
        )
        XCTAssertEqual(pending.title, "Weekly sync")
        XCTAssertEqual(pending.sidecar?.language, .english)
        XCTAssertEqual(pending.sidecar?.lastError, "Upload failed")
        XCTAssertEqual(pending.sidecar?.meeting?.url, "https://meet.google.com/abc-defg-hij")
    }

    func testReferencedFilesIncludeDocIDsForOlderTranscripts() throws {
        let json = """
        {"id":"2026-01-02_090000","title":"Old","date":"2026-01-02T09:00:00Z","duration":60,
         "language":"pl","modelShortName":"large-v3","sourceKind":"live","speakers":[],"segments":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(TranscriptDocument.self, from: Data(json.utf8))

        XCTAssertTrue(PendingRecordingStore.referencedVoiceFiles(in: [doc])
            .contains("2026-01-02_090000.voice.wav"))
    }

    func testDeleteRemovesEveryFile() throws {
        for name in ["2026-01-02_090000.voice.wav", "2026-01-02_090000.system.wav",
                     "2026-01-02_090000.video.mp4", "2026-01-02_090000.meta.json"] {
            try makeStem(name, seconds: 5)
        }
        let pending = try XCTUnwrap(
            PendingRecordingStore.scan(recordingsDir: dir, referencedVoiceFiles: []).first
        )
        PendingRecordingStore.delete(pending, in: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    /// File of the size a stem of `seconds` would have (4 KB header + 16-bit 16 kHz).
    private func makeStem(_ name: String, seconds: Int) throws {
        try Data(count: 4096 + seconds * 32_000).write(to: dir.appendingPathComponent(name))
    }
}
