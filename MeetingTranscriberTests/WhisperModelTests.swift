import XCTest
@testable import MeetingTranscriber

/// Routing flags on the transcription-model picker enum.
final class WhisperModelTests: XCTestCase {

    func testMAIIsTheDefaultModel() {
        XCTAssertEqual(WhisperModel.defaultModel, .maiTranscribe2)
    }

    func testBothCloudEnginesAreCloudAndNotParakeet() {
        XCTAssertTrue(WhisperModel.maiTranscribe2.isCloud)
        XCTAssertTrue(WhisperModel.scribeV2.isCloud)
        XCTAssertFalse(WhisperModel.maiTranscribe2.isParakeet)
        XCTAssertEqual(WhisperModel.allCases.filter(\.isCloud), [.scribeV2, .maiTranscribe2])
    }

    func testShortNamesAreUnique() {
        // Re-transcribe offers every model whose shortName differs from the
        // document's, so a collision would hide an engine.
        let names = WhisperModel.allCases.map(\.shortName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(WhisperModel.maiTranscribe2.shortName, "mai-transcribe-2")
    }
}
