import Foundation
import UserNotifications

/// Decides when the "still recording" notification fires. One instance lives
/// per recording session (AppState makes a fresh one on every start), so the
/// notification can fire at most once per recording.
struct LongRecordingAlert {
    /// Seconds of recording before the notice fires. 2 hours by default —
    /// long enough that any normal meeting has ended, short enough to save
    /// most of an accidentally-forgotten overnight recording.
    var thresholdSeconds: Int

    private var didFire = false

    init(thresholdSeconds: Int = 7_200) {
        self.thresholdSeconds = thresholdSeconds
    }

    /// Returns true exactly once, on the first check at or past the threshold.
    mutating func check(elapsedSeconds: Int) -> Bool {
        guard !didFire, elapsedSeconds >= thresholdSeconds else { return false }
        didFire = true
        return true
    }
}

/// Posts the user notification behind `LongRecordingAlert`.
///
/// The delegate exists because banners are suppressed by default while the
/// app is frontmost — and someone reviewing transcripts in the main window is
/// exactly who needs to hear that a recording is still running.
final class LongRecordingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LongRecordingNotifier()

    /// Called when a recording starts, so the permission prompt appears in
    /// context the first time and the notification is deliverable by the time
    /// the threshold hits.
    func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                Log.recorder.info("Long-recording notice unavailable: notifications not authorized")
            }
        }
    }

    func postLongRecordingNotice(elapsedSeconds: Int) {
        let hours = elapsedSeconds / 3_600
        let content = UNMutableNotificationContent()
        content.title = "Still recording"
        content.body = "This recording has been running for \(hours) hours. Stop it if the meeting is over."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "long-recording",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
