import XCTest
@testable import MeetingTranscriber

final class InputDeviceSelectionTests: XCTestCase {

    private let builtIn = InputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let airpods = InputDevice(id: 77, uid: "AirPods-UID", name: "AirPods Pro")

    func testNilPreferenceMeansSystemDefault() {
        XCTAssertNil(InputDeviceSelection.resolve(preferredUID: nil, available: [builtIn, airpods]))
    }

    func testEmptyPreferenceMeansSystemDefault() {
        XCTAssertNil(InputDeviceSelection.resolve(preferredUID: "", available: [builtIn, airpods]))
    }

    func testPreferredDeviceIsReturnedWhenPresent() {
        XCTAssertEqual(InputDeviceSelection.resolve(preferredUID: "AirPods-UID",
                                                    available: [builtIn, airpods]), airpods)
    }

    func testMissingPreferredDeviceFallsBackToDefault() {
        XCTAssertNil(InputDeviceSelection.resolve(preferredUID: "Unplugged-USB",
                                                  available: [builtIn, airpods]))
    }
}
