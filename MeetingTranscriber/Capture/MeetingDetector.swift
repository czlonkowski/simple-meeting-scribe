import Foundation
import AppKit

/// Polls running browsers for the active tab URL and emits `onMeetingDetected`
/// when the URL matches a known meeting pattern. Supports Arc, Safari, and
/// Google Chrome — any combination can be running; the detector picks up
/// whichever one has a meeting tab.
final class MeetingDetector {
    struct Pattern { let name: String; let regex: NSRegularExpression }

    /// One browser we know how to query via AppleScript.
    private struct Browser {
        let name: String          // shown to the user / used for log messages
        let bundleID: String
        /// AppleScript source. Must return the front window's active tab URL,
        /// or an empty string when there's nothing to report. Each browser has
        /// its own terminology (Safari uses `current tab`, others `active tab`).
        let scriptSource: String
    }

    private static let browsers: [Browser] = [
        Browser(
            name: "Arc",
            bundleID: "company.thebrowser.Browser",
            scriptSource: """
            tell application "Arc"
                if not running then return ""
                if (count of windows) = 0 then return ""
                try
                    return URL of active tab of front window
                on error
                    return ""
                end try
            end tell
            """
        ),
        Browser(
            name: "Safari",
            bundleID: "com.apple.Safari",
            scriptSource: """
            tell application "Safari"
                if not running then return ""
                if (count of windows) = 0 then return ""
                try
                    return URL of current tab of front window
                on error
                    return ""
                end try
            end tell
            """
        ),
        Browser(
            name: "Chrome",
            bundleID: "com.google.Chrome",
            scriptSource: """
            tell application "Google Chrome"
                if not running then return ""
                if (count of windows) = 0 then return ""
                try
                    return URL of active tab of front window
                on error
                    return ""
                end try
            end tell
            """
        ),
    ]

    private var patterns: [Pattern] = []
    private var pollTimer: Timer?
    private var lastReportedURL: String?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    var onMeetingDetected: ((DetectedMeeting) -> Void)?

    func start() {
        patterns = Self.loadPatterns()
        let supportedIDs = Set(Self.browsers.map(\.bundleID))

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, supportedIDs.contains(id)
            else { return }
            self.ensureTimerRunning()
        }
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, supportedIDs.contains(id)
            else { return }
            // Timer stays on as long as *any* supported browser is running.
            if self.runningBrowsers().isEmpty { self.stopTimer() }
        }

        if !runningBrowsers().isEmpty { ensureTimerRunning() }
    }

    func stop() {
        stopTimer()
        if let obs = launchObserver    { NotificationCenter.default.removeObserver(obs) }
        if let obs = terminateObserver { NotificationCenter.default.removeObserver(obs) }
    }

    private func runningBrowsers() -> [Browser] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.browsers.filter { running.contains($0.bundleID) }
    }

    private func ensureTimerRunning() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        poll()
    }

    private func stopTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        lastReportedURL = nil
    }

    private func poll() {
        let running = runningBrowsers()
        guard !running.isEmpty else { stopTimer(); return }

        // Ask each running browser for its active URL and return the first
        // meeting match. Browsers are tried in the declared order (Arc first).
        for browser in running {
            guard let url = fetchURL(from: browser), !url.isEmpty else { continue }
            guard let pattern = patterns.first(where: { $0.regex.firstMatch(
                in: url, range: NSRange(url.startIndex..., in: url)) != nil })
            else { continue }

            if url == lastReportedURL { return }
            lastReportedURL = url
            let meeting = DetectedMeeting(
                title: meetingTitle(for: url, platform: pattern.name),
                platform: pattern.name,
                url: url,
                detectedAt: Date()
            )
            onMeetingDetected?(meeting)
            return
        }

        // No matches right now — keep lastReportedURL so a tab-switch back
        // to the same meeting URL doesn't immediately re-trigger.
    }

    private func fetchURL(from browser: Browser) -> String? {
        guard let script = NSAppleScript(source: browser.scriptSource) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    private func meetingTitle(for url: String, platform: String) -> String {
        if let comp = URLComponents(string: url) {
            let segs = comp.path.split(separator: "/").map(String.init)
            if let last = segs.last, !last.isEmpty { return "\(platform) — \(last)" }
        }
        return platform
    }

    private static func loadPatterns() -> [Pattern] {
        guard let url = Bundle.main.url(forResource: "meeting-patterns", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["patterns"] as? [[String: Any]]
        else { return [] }
        return arr.compactMap { dict in
            guard let name = dict["name"] as? String,
                  let raw = dict["regex"] as? String,
                  let regex = try? NSRegularExpression(pattern: raw, options: [.caseInsensitive])
            else { return nil }
            return Pattern(name: name, regex: regex)
        }
    }
}
