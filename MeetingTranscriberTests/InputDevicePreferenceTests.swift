import XCTest
@testable import MeetingTranscriber

/// Settings holds the persisted *preferred* mic; the record card can override
/// it for the current session only. These pin how the two combine.
final class InputDevicePreferenceTests: XCTestCase {

    private let builtIn = InputDevice(id: 41, uid: "BuiltIn", name: "MacBook Pro Microphone")
    private let airpods = InputDevice(id: 77, uid: "AirPods", name: "AirPods Pro")

    func testSessionOverrideWinsOverPreferred() {
        XCTAssertEqual(InputDeviceSelection.effectiveUID(sessionOverride: "BuiltIn",
                                                         preferred: "AirPods"), "BuiltIn")
    }

    func testNoOverrideUsesPreferred() {
        XCTAssertEqual(InputDeviceSelection.effectiveUID(sessionOverride: nil,
                                                         preferred: "AirPods"), "AirPods")
    }

    func testNothingSetMeansSystemDefault() {
        XCTAssertNil(InputDeviceSelection.effectiveUID(sessionOverride: nil, preferred: nil))
        XCTAssertNil(InputDeviceSelection.effectiveUID(sessionOverride: "", preferred: ""))
    }

    func testDefaultLabelNamesConnectedPreferredDevice() {
        XCTAssertEqual(InputDeviceSelection.defaultLabel(preferred: "AirPods",
                                                         available: [builtIn, airpods]),
                       "Default (AirPods Pro)")
    }

    func testDefaultLabelFallsBackWhenPreferredDisconnected() {
        XCTAssertEqual(InputDeviceSelection.defaultLabel(preferred: "AirPods",
                                                         available: [builtIn]),
                       "System Default")
    }

    func testDefaultLabelWithoutPreference() {
        XCTAssertEqual(InputDeviceSelection.defaultLabel(preferred: nil, available: [builtIn]),
                       "System Default")
    }
}
