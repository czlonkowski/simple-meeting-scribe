import Foundation
import XCTest
@testable import MeetingTranscriber

final class MeetingDetectorTests: XCTestCase {
    private let arc = BrowserDescriptor(
        name: "Arc",
        bundleID: "company.thebrowser.Browser",
        scriptSource: ""
    )
    private let safari = BrowserDescriptor(
        name: "Safari",
        bundleID: "com.apple.Safari",
        scriptSource: ""
    )
    private let chrome = BrowserDescriptor(
        name: "Chrome",
        bundleID: "com.google.Chrome",
        scriptSource: ""
    )

    @MainActor
    func testTimedOutSafariDoesNotBlockChromeDetection() async throws {
        let query = FakeBrowserQuery(results: [
            arc.bundleID: .noURL,
            safari.bundleID: .timedOut,
            chrome.bundleID: .url("https://meet.google.com/abc-defg-hij"),
        ])
        let detected = expectation(description: "Chrome meeting detected")
        let detector = makeDetector(query: query)
        detector.onMeetingDetected = { meeting in
            XCTAssertEqual(meeting.browserBundleID, self.chrome.bundleID)
            detected.fulfill()
        }

        detector.start()
        await fulfillment(of: [detected], timeout: 1)
        detector.stop()
    }

    @MainActor
    func testConfiguredBrowserPriorityWinsConcurrentMatches() async throws {
        let query = FakeBrowserQuery(results: [
            arc.bundleID: .url("https://meet.google.com/arc-room"),
            safari.bundleID: .url("https://meet.google.com/safari-room"),
            chrome.bundleID: .url("https://meet.google.com/chrome-room"),
        ])
        let detected = expectation(description: "Highest-priority meeting detected")
        let detector = makeDetector(query: query)
        detector.onMeetingDetected = { meeting in
            XCTAssertEqual(meeting.browserBundleID, self.arc.bundleID)
            detected.fulfill()
        }

        detector.start()
        await fulfillment(of: [detected], timeout: 1)
        detector.stop()
    }

    @MainActor
    func testPollingCyclesNeverOverlap() async throws {
        let query = FakeBrowserQuery(
            results: [arc.bundleID: .noURL],
            delays: [arc.bundleID: 50_000_000]
        )
        let detector = makeDetector(
            browsers: [arc],
            query: query,
            pollIntervalNanoseconds: 5_000_000
        )

        detector.start()
        try await Task.sleep(nanoseconds: 140_000_000)
        detector.stop()

        let maximumConcurrency = await query.maximumConcurrentQueries
        XCTAssertEqual(maximumConcurrency, 1)
    }

    @MainActor
    func testStopSuppressesLateCallbacks() async throws {
        let query = FakeBrowserQuery(
            results: [arc.bundleID: .url("https://meet.google.com/late-room")],
            delays: [arc.bundleID: 200_000_000]
        )
        let detector = makeDetector(browsers: [arc], query: query)
        var callbackCount = 0
        detector.onMeetingDetected = { _ in callbackCount += 1 }

        detector.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        detector.stop()
        try await Task.sleep(nanoseconds: 240_000_000)

        XCTAssertEqual(callbackCount, 0)
    }

    @MainActor
    func testDuplicateURLIsEmittedOnlyOnce() async throws {
        let query = FakeBrowserQuery(
            results: [arc.bundleID: .url("https://meet.google.com/same-room")]
        )
        let firstDetection = expectation(description: "First detection")
        let detector = makeDetector(
            browsers: [arc],
            query: query,
            pollIntervalNanoseconds: 5_000_000
        )
        var callbackCount = 0
        detector.onMeetingDetected = { _ in
            callbackCount += 1
            firstDetection.fulfill()
        }

        detector.start()
        await fulfillment(of: [firstDetection], timeout: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        detector.stop()

        XCTAssertEqual(callbackCount, 1)
    }

    @MainActor
    func testStopAndRestartResetsDuplicateSuppression() async throws {
        let query = FakeBrowserQuery(
            results: [arc.bundleID: .url("https://meet.google.com/reopened-room")]
        )
        let detections = expectation(description: "Detection after each start")
        detections.expectedFulfillmentCount = 2
        let detector = makeDetector(browsers: [arc], query: query)
        detector.onMeetingDetected = { _ in detections.fulfill() }

        detector.start()
        try await Task.sleep(nanoseconds: 40_000_000)
        detector.stop()
        detector.start()
        await fulfillment(of: [detections], timeout: 1)
        detector.stop()
    }

    @MainActor
    func testCompletedOldPollCannotDetachRestartedPollingTask() async throws {
        let query = RestartRaceQuery()
        let detector = makeDetector(
            browsers: [arc],
            query: query,
            pollIntervalNanoseconds: 5_000_000
        )
        var callbackCount = 0
        detector.onMeetingDetected = { _ in callbackCount += 1 }

        detector.start()
        try await Task.sleep(nanoseconds: 10_000_000)
        detector.stop()
        detector.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        detector.stop()

        let countAtStop = callbackCount
        XCTAssertGreaterThan(countAtStop, 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(callbackCount, countAtStop)
    }

    @MainActor
    func testFailuresAndEmptyResultsDoNotEmitMeetings() async throws {
        let query = FakeBrowserQuery(results: [
            arc.bundleID: .failed("Automation denied"),
            safari.bundleID: .noURL,
            chrome.bundleID: .cancelled,
        ])
        let detector = makeDetector(
            query: query,
            pollIntervalNanoseconds: 5_000_000
        )
        var callbackCount = 0
        detector.onMeetingDetected = { _ in callbackCount += 1 }

        detector.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        detector.stop()

        XCTAssertEqual(callbackCount, 0)
    }

    @MainActor
    private func makeDetector(
        browsers: [BrowserDescriptor]? = nil,
        query: any BrowserURLQuerying,
        pollIntervalNanoseconds: UInt64 = 1_000_000_000
    ) -> MeetingDetector {
        let selectedBrowsers = browsers ?? [arc, safari, chrome]
        let ids = Set(selectedBrowsers.map(\.bundleID))
        return MeetingDetector(
            browsers: selectedBrowsers,
            patterns: [
                MeetingDetector.Pattern(
                    name: "Google Meet",
                    regex: try! NSRegularExpression(pattern: #"meet\.google\.com/"#)
                ),
            ],
            query: query,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            runningBrowserIDs: { ids },
            workspaceNotificationCenter: nil
        )
    }
}

private actor FakeBrowserQuery: BrowserURLQuerying {
    private let results: [String: BrowserURLQueryResult]
    private let delays: [String: UInt64]
    private var concurrentQueries = 0
    private(set) var maximumConcurrentQueries = 0

    init(
        results: [String: BrowserURLQueryResult],
        delays: [String: UInt64] = [:]
    ) {
        self.results = results
        self.delays = delays
    }

    func activeURL(for browser: BrowserDescriptor) async -> BrowserURLQueryResult {
        concurrentQueries += 1
        maximumConcurrentQueries = max(maximumConcurrentQueries, concurrentQueries)
        defer { concurrentQueries -= 1 }

        if let delay = delays[browser.bundleID] {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return .cancelled
            }
        }
        return results[browser.bundleID] ?? .noURL
    }
}

private actor RestartRaceQuery: BrowserURLQuerying {
    private var invocationCount = 0

    func activeURL(for browser: BrowserDescriptor) async -> BrowserURLQueryResult {
        invocationCount += 1
        let invocation = invocationCount
        if invocation == 1 {
            // Deliberately simulate a dependency that finishes after cancellation.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .url("https://meet.google.com/restart-room-\(invocation)")
    }
}
