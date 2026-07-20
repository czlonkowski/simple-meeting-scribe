import AppKit
import Foundation

/// Polls running browsers for the active tab URL and emits `onMeetingDetected`
/// when the URL matches a known meeting pattern. Browser automation is isolated
/// in bounded helper processes so a hung browser can never block AppKit.
@MainActor
final class MeetingDetector {
    struct Pattern {
        let name: String
        let regex: NSRegularExpression
    }

    typealias RunningBrowserProvider = @MainActor @Sendable () -> Set<String>

    static let defaultBrowsers: [BrowserDescriptor] = [
        BrowserDescriptor(
            name: "Arc",
            bundleID: "company.thebrowser.Browser",
            scriptSource: """
            tell application "Arc"
                if not running then return ""
                if (count of windows) = 0 then return ""
                return URL of active tab of front window
            end tell
            """
        ),
        BrowserDescriptor(
            name: "Safari",
            bundleID: "com.apple.Safari",
            scriptSource: """
            tell application "Safari"
                if not running then return ""
                if (count of windows) = 0 then return ""
                return URL of current tab of front window
            end tell
            """
        ),
        BrowserDescriptor(
            name: "Chrome",
            bundleID: "com.google.Chrome",
            scriptSource: """
            tell application "Google Chrome"
                if not running then return ""
                if (count of windows) = 0 then return ""
                return URL of active tab of front window
            end tell
            """
        ),
    ]

    private let browsers: [BrowserDescriptor]
    private let query: any BrowserURLQuerying
    private let pollIntervalNanoseconds: UInt64
    private let runningBrowserIDs: RunningBrowserProvider
    private let workspaceNotificationCenter: NotificationCenter?
    private var patterns: [Pattern]
    private var pollTask: Task<Void, Never>?
    private var pollGeneration: UInt = 0
    private var lastReportedURL: String?
    private var failingBrowserIDs: Set<String> = []
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var isStarted = false

    var onMeetingDetected: ((DetectedMeeting) -> Void)?

    init(
        browsers: [BrowserDescriptor] = MeetingDetector.defaultBrowsers,
        patterns: [Pattern] = [],
        query: any BrowserURLQuerying = OSAScriptBrowserURLQuery(),
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        runningBrowserIDs: @escaping RunningBrowserProvider = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        workspaceNotificationCenter: NotificationCenter? = NSWorkspace.shared.notificationCenter
    ) {
        self.browsers = browsers
        self.patterns = patterns
        self.query = query
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.runningBrowserIDs = runningBrowserIDs
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if patterns.isEmpty {
            patterns = Self.loadPatterns()
        }

        let supportedIDs = Set(browsers.map(\.bundleID))
        if let notificationCenter = workspaceNotificationCenter {
            launchObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                Task { @MainActor in
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication,
                          let id = app.bundleIdentifier,
                          supportedIDs.contains(id)
                    else { return }
                    self?.ensurePolling()
                }
            }
            terminateObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                Task { @MainActor in
                    guard let self,
                          let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication,
                          let id = app.bundleIdentifier,
                          supportedIDs.contains(id)
                    else { return }
                    if self.runningBrowsers().isEmpty {
                        self.stopPolling(resetLastURL: true)
                    }
                }
            }
        }

        if !runningBrowsers().isEmpty {
            ensurePolling()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        stopPolling(resetLastURL: true)
        if let launchObserver {
            workspaceNotificationCenter?.removeObserver(launchObserver)
        }
        if let terminateObserver {
            workspaceNotificationCenter?.removeObserver(terminateObserver)
        }
        launchObserver = nil
        terminateObserver = nil
    }

    private func runningBrowsers() -> [BrowserDescriptor] {
        let running = runningBrowserIDs()
        return browsers.filter { running.contains($0.bundleID) }
    }

    private func ensurePolling() {
        guard isStarted, pollTask == nil else { return }
        pollGeneration &+= 1
        let generation = pollGeneration
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.pollGeneration == generation {
                    self.pollTask = nil
                }
            }

            while !Task.isCancelled {
                guard await self.pollOnce() else { return }
                do {
                    try await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    private func stopPolling(resetLastURL: Bool) {
        pollGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        failingBrowserIDs.removeAll()
        if resetLastURL {
            lastReportedURL = nil
        }
    }

    private func pollOnce() async -> Bool {
        let running = runningBrowsers()
        guard !running.isEmpty else {
            lastReportedURL = nil
            return false
        }

        let results = await withTaskGroup(
            of: (String, BrowserURLQueryResult).self,
            returning: [String: BrowserURLQueryResult].self
        ) { group in
            for browser in running {
                group.addTask { [query] in
                    (browser.bundleID, await query.activeURL(for: browser))
                }
            }

            var collected: [String: BrowserURLQueryResult] = [:]
            for await (bundleID, result) in group {
                collected[bundleID] = result
            }
            return collected
        }

        guard !Task.isCancelled else { return false }

        for browser in running {
            guard let result = results[browser.bundleID] else { continue }
            logTransition(for: browser, result: result)
            guard case .url(let url) = result,
                  let pattern = patterns.first(where: { $0.regex.firstMatch(
                    in: url,
                    range: NSRange(url.startIndex..., in: url)
                  ) != nil })
            else { continue }

            if url == lastReportedURL { return true }
            lastReportedURL = url
            onMeetingDetected?(DetectedMeeting(
                title: meetingTitle(for: url, platform: pattern.name),
                platform: pattern.name,
                url: url,
                detectedAt: Date(),
                browserBundleID: browser.bundleID
            ))
            return true
        }

        // Preserve the last reported URL so switching away and immediately
        // back to the same meeting tab does not re-trigger the sheet.
        return true
    }

    private func logTransition(for browser: BrowserDescriptor, result: BrowserURLQueryResult) {
        switch result {
        case .timedOut:
            if failingBrowserIDs.insert(browser.bundleID).inserted {
                Log.browserDetection.warning("\(browser.name, privacy: .public) query timed out")
            }
        case .failed(let message):
            if failingBrowserIDs.insert(browser.bundleID).inserted {
                Log.browserDetection.warning(
                    "\(browser.name, privacy: .public) query failed: \(message, privacy: .public)"
                )
            }
        case .url, .noURL:
            if failingBrowserIDs.remove(browser.bundleID) != nil {
                Log.browserDetection.notice("\(browser.name, privacy: .public) query recovered")
            }
        case .cancelled:
            break
        }
    }

    private func meetingTitle(for url: String, platform: String) -> String {
        if let components = URLComponents(string: url) {
            let segments = components.path.split(separator: "/").map(String.init)
            if let last = segments.last, !last.isEmpty {
                return "\(platform) — \(last)"
            }
        }
        return platform
    }

    private static func loadPatterns() -> [Pattern] {
        guard let url = Bundle.main.url(forResource: "meeting-patterns", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPatterns = json["patterns"] as? [[String: Any]]
        else { return [] }

        return rawPatterns.compactMap { dictionary in
            guard let name = dictionary["name"] as? String,
                  let rawRegex = dictionary["regex"] as? String,
                  let regex = try? NSRegularExpression(
                    pattern: rawRegex,
                    options: [.caseInsensitive]
                  )
            else { return nil }
            return Pattern(name: name, regex: regex)
        }
    }
}
