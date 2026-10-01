import Foundation

/// One CoreAudio client process as seen in a single poll.
struct AudioClientSnapshot: Equatable, Sendable {
    let pid: Int32
    let bundleID: String
    let executablePath: String
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

/// A native app that places voice calls. Matched against CoreAudio clients by
/// bundle-ID prefix (apps often play audio from helper processes such as
/// `net.whatsapp.WhatsApp.helper`) or by executable name for daemons that
/// report no bundle ID.
struct CallApp: Equatable, Sendable {
    let name: String
    let bundleIDPrefixes: [String]
    var executableNames: [String] = []
    /// App whose window the screen recorder should look for.
    let windowBundleID: String
    /// Processes whose output is the remote side of the call, for apps whose
    /// audio ScreenCaptureKit cannot see. Empty = the normal system stem.
    var tapExecutableNames: [String] = []

    func matches(_ client: AudioClientSnapshot) -> Bool {
        let bundle = client.bundleID.lowercased()
        if bundleIDPrefixes.contains(where: { bundle.hasPrefix($0.lowercased()) }) { return true }
        let executable = (client.executablePath as NSString).lastPathComponent
        return executableNames.contains(executable)
    }

    static let defaults: [CallApp] = [
        CallApp(name: "WhatsApp", bundleIDPrefixes: ["net.whatsapp."],
                windowBundleID: "net.whatsapp.WhatsApp"),
        // iPhone calls relayed through Continuity are carried by the
        // telephony/conferencing daemons, not by FaceTime.app itself.
        // Verified on a live call 2026-10-01: `avconferenced` runs mic + speaker
        // while Phone.app (com.apple.mobilephone) only plays UI sounds.
        CallApp(name: "Phone", bundleIDPrefixes: ["com.apple.avconferenced", "com.apple.FaceTime"],
                executableNames: ["avconferenced"],
                windowBundleID: "com.apple.FaceTime",
                tapExecutableNames: ["avconferenced"]),
        CallApp(name: "Signal", bundleIDPrefixes: ["org.whispersystems.signal-desktop"],
                windowBundleID: "org.whispersystems.signal-desktop"),
        CallApp(name: "Telegram", bundleIDPrefixes: ["ru.keepcoder.Telegram"],
                windowBundleID: "ru.keepcoder.Telegram"),
        CallApp(name: "Zoom", bundleIDPrefixes: ["us.zoom."], windowBundleID: "us.zoom.xos"),
        CallApp(name: "Microsoft Teams", bundleIDPrefixes: ["com.microsoft.teams"],
                windowBundleID: "com.microsoft.teams2"),
        CallApp(name: "Slack", bundleIDPrefixes: ["com.tinyspeck.slackmacgap"],
                windowBundleID: "com.tinyspeck.slackmacgap"),
    ]
}

/// Turns a stream of CoreAudio client snapshots into "a call started" events.
///
/// A call is an allowlisted app that both captures the mic and plays audio,
/// continuously, for `minimumDuration`. Requiring both directions rejects voice
/// notes and dictation (input only) and message playback (output only); the
/// delay rejects the ringtone and call-preview blips. A call ends — and the app
/// becomes eligible to trigger again — once it stops capturing the mic.
struct CallActivityTracker {
    struct CallStart: Equatable {
        let app: CallApp
        let startedAt: Date
    }

    let apps: [CallApp]
    var minimumDuration: TimeInterval = 3

    /// When each app was first seen in a two-way state, while it still is.
    private var twoWaySince: [String: Date] = [:]
    /// Apps already reported whose mic capture hasn't stopped yet.
    private var reported: Set<String> = []

    init(apps: [CallApp] = CallApp.defaults, minimumDuration: TimeInterval = 3) {
        self.apps = apps
        self.minimumDuration = minimumDuration
    }

    mutating func update(clients: [AudioClientSnapshot], at now: Date) -> [CallStart] {
        var starts: [CallStart] = []
        for app in apps {
            let mine = clients.filter(app.matches)
            let capturing = mine.contains(where: \.isRunningInput)
            let playing = mine.contains(where: \.isRunningOutput)

            if !capturing {
                reported.remove(app.name)
            }
            guard capturing && playing else {
                twoWaySince[app.name] = nil
                continue
            }
            let since = twoWaySince[app.name] ?? now
            twoWaySince[app.name] = since
            if !reported.contains(app.name), now.timeIntervalSince(since) >= minimumDuration {
                reported.insert(app.name)
                starts.append(CallStart(app: app, startedAt: since))
            }
        }
        return starts
    }
}
