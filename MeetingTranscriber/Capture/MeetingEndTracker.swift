import Foundation

/// Decides when a running recording looks like its meeting is over, so the app
/// can ask whether to stop. It only ever proposes; the user decides.
///
/// Two signals, checked once per second:
/// - **App left:** a meeting app (browser, Teams, Zoom…) used the mic during
///   the recording and has now stopped for `releaseGrace`, while no remote
///   audio played. Leaving a Meet/Teams call closes the browser's mic stream.
///   Requiring quiet system audio keeps a mic released by muting from firing
///   while others are still talking.
/// - **Silence:** neither side has spoken for `silenceWindow`. Measured on
///   recordings from Sep–Oct 2026, the longest shared quiet inside a real
///   meeting was 49 s, so 3 minutes leaves a wide margin.
///
/// Each signal fires once and re-arms only after the meeting comes back
/// (the app uses the mic again, or someone speaks).
struct MeetingEndTracker {
    enum Reason: Equatable {
        case appLeft
        case silence
    }

    /// Bundle-ID prefixes of processes that carry a meeting's mic stream.
    /// Browsers run WebRTC in helper processes (`company.thebrowser.browser.helper`,
    /// `com.google.Chrome.helper`); Safari's goes through the WebKit GPU process.
    static let meetingAppBundlePrefixes = [
        "company.thebrowser.",
        "com.google.chrome",
        "com.apple.webkit",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "org.mozilla.firefox",
        "com.microsoft.teams",
        "us.zoom.",
        "com.tinyspeck.slackmacgap",
        "com.cisco.webexmeetingsapp",
        "com.webex.",
    ]

    static func isMeetingApp(_ client: AudioClientSnapshot) -> Bool {
        let bundle = client.bundleID.lowercased()
        return meetingAppBundlePrefixes.contains { bundle.hasPrefix($0) }
    }

    /// Seconds of mic use by a meeting app before its release counts.
    var minimumAppUse: Int = 5
    /// Seconds the meeting app must stay off the mic, with quiet system audio.
    var releaseGrace: Int = 10
    /// Seconds with neither side speaking.
    var silenceWindow: Int = 180
    /// Per-second RMS below which a side counts as quiet. −50 dBFS for remote
    /// audio, −45 dBFS for the mic (room noise on the RØDE sits around −60…−90).
    var systemQuietRMS: Float = 0.003_2
    var micQuietRMS: Float = 0.005_6

    private var appUseSeconds = 0
    private var appOffSeconds = 0
    private var systemQuietSeconds = 0
    private var bothQuietSeconds = 0
    private var appLeftArmed = true
    private var silenceArmed = true

    /// Feed one second of state. Returns a reason the first time a signal fires.
    mutating func tick(meetingAppUsesMic: Bool, systemRMS: Float, micRMS: Float) -> Reason? {
        let systemQuiet = systemRMS < systemQuietRMS
        let micQuiet = micRMS < micQuietRMS
        systemQuietSeconds = systemQuiet ? systemQuietSeconds + 1 : 0
        bothQuietSeconds = systemQuiet && micQuiet ? bothQuietSeconds + 1 : 0
        if !(systemQuiet && micQuiet) { silenceArmed = true }

        if meetingAppUsesMic {
            appUseSeconds += 1
            appOffSeconds = 0
            appLeftArmed = true
        } else {
            appOffSeconds += 1
        }

        if appLeftArmed, appUseSeconds >= minimumAppUse,
           appOffSeconds >= releaseGrace, systemQuietSeconds >= releaseGrace {
            appLeftArmed = false
            silenceArmed = false
            return .appLeft
        }
        if silenceArmed, bothQuietSeconds >= silenceWindow {
            silenceArmed = false
            return .silence
        }
        return nil
    }
}

/// Mean-square accumulator: turns the per-buffer RMS callbacks into one RMS
/// per second, the unit the tracker's thresholds were measured in.
struct LevelAccumulator {
    private var sumOfSquares: Float = 0
    private var count = 0

    mutating func add(_ rms: Float) {
        sumOfSquares += rms * rms
        count += 1
    }

    /// RMS since the last call, then resets. 0 when nothing arrived.
    mutating func take() -> Float {
        defer { sumOfSquares = 0; count = 0 }
        return count == 0 ? 0 : (sumOfSquares / Float(count)).squareRoot()
    }
}
