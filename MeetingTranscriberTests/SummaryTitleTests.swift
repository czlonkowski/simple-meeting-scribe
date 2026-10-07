import XCTest
@testable import MeetingTranscriber

final class SummaryTitleTests: XCTestCase {
    func testCallPlaceholderTitlesAreReplaceable() {
        for app in CallApp.defaults {
            XCTAssertTrue(SummaryPrompts.isPlaceholderTitle(app.callTitle, sourceFilename: nil), app.callTitle)
        }
        XCTAssertTrue(SummaryPrompts.isPlaceholderTitle("WhatsApp call", sourceFilename: nil))
        XCTAssertTrue(SummaryPrompts.isPlaceholderTitle("Phone call", sourceFilename: nil))
    }

    func testExistingPlaceholdersStayReplaceable() {
        XCTAssertTrue(SummaryPrompts.isPlaceholderTitle("", sourceFilename: nil))
        XCTAssertTrue(SummaryPrompts.isPlaceholderTitle("Recording — 7 Oct 2026", sourceFilename: nil))
        XCTAssertTrue(SummaryPrompts.isPlaceholderTitle("Google Meet — abc-defg-hij", sourceFilename: nil))
        XCTAssertTrue(SummaryPrompts.isPlaceholderTitle("notes.txt", sourceFilename: "notes.txt"))
        XCTAssertTrue(SummaryPrompts.isPlaceholderTitle("Interview.M4A", sourceFilename: nil))
    }

    func testUserEditedTitlesArePreserved() {
        XCTAssertFalse(SummaryPrompts.isPlaceholderTitle("Phone call with Anna about pricing", sourceFilename: nil))
        XCTAssertFalse(SummaryPrompts.isPlaceholderTitle("Budżet Q4", sourceFilename: nil))
    }
}
