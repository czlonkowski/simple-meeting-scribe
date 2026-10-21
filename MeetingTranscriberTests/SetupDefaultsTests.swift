import XCTest
@testable import MeetingTranscriber

final class SetupDefaultsTests: XCTestCase {
    func testFreshInstallWithoutKeysStartsLocal() {
        XCTAssertEqual(SetupDefaults.initialEngine(stored: nil, hasMAIKey: false, hasScribeKey: false), .largeV3Turbo)
    }

    func testExistingKeysKeepTheCloudDefault() {
        XCTAssertEqual(SetupDefaults.initialEngine(stored: nil, hasMAIKey: true, hasScribeKey: true), .maiTranscribe2)
        XCTAssertEqual(SetupDefaults.initialEngine(stored: nil, hasMAIKey: false, hasScribeKey: true), .scribeV2)
    }

    func testSavedChoiceWins() {
        XCTAssertEqual(SetupDefaults.initialEngine(stored: .parakeetV3, hasMAIKey: true, hasScribeKey: true), .parakeetV3)
    }

    func testAssistantOpensOnlyOnAFreshInstall() {
        XCTAssertTrue(SetupDefaults.shouldShowSetup(completed: false, hasTranscripts: false, hasCloudKeys: false))
        XCTAssertFalse(SetupDefaults.shouldShowSetup(completed: true, hasTranscripts: false, hasCloudKeys: false))
        XCTAssertFalse(SetupDefaults.shouldShowSetup(completed: false, hasTranscripts: true, hasCloudKeys: false))
        XCTAssertFalse(SetupDefaults.shouldShowSetup(completed: false, hasTranscripts: false, hasCloudKeys: true))
    }

    func testCloudEnginePrefersMAI() {
        XCTAssertEqual(SetupDefaults.cloudEngine(hasMAIKey: true, hasScribeKey: true), .maiTranscribe2)
        XCTAssertEqual(SetupDefaults.cloudEngine(hasMAIKey: false, hasScribeKey: true), .scribeV2)
        XCTAssertNil(SetupDefaults.cloudEngine(hasMAIKey: false, hasScribeKey: false))
    }
}
