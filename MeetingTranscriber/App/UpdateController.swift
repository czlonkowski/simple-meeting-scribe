import Foundation
import Observation
import Sparkle

/// Sparkle updates from published GitHub Releases, held back while the app
/// is recording or transcribing. A relaunch mid-recording would cut the
/// meeting, and the transcription queue is in memory only, so a relaunch
/// mid-transcription would drop the queued recordings.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    /// Version waiting for the app to become idle before it installs.
    private(set) var pendingInstallVersion: String?
    private(set) var canCheckForUpdates = false

    /// Debug builds are installed by `scripts/reinstall.sh`; Sparkle must
    /// never replace them with a release build.
    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var backgroundCheckDeferred = false
    @ObservationIgnored private var isWatchingForIdle = false

    init(appState: AppState) {
        self.appState = appState
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.isEnabled, updaterDelegate: self, userDriverDelegate: nil
        )
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = Self.isEnabled && canCheck }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { access(keyPath: \.automaticallyChecksForUpdates); return controller.updater.automaticallyChecksForUpdates }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether an update must wait. `preparing` and `stopping` count as busy:
    /// the recorder still owns the capture files then.
    nonisolated static func mustDefer(recordingState: AppState.RecordingState, isProcessing: Bool) -> Bool {
        recordingState.isBusy || isProcessing
    }

    private var mustDefer: Bool {
        Self.mustDefer(recordingState: appState.recordingState, isProcessing: appState.isProcessing)
    }

    // MARK: – SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // A scheduled check would pop the update window over a meeting or a
        // shared screen. Run it once the app is idle instead.
        guard updateCheck == .updatesInBackground, mustDefer else { return }
        backgroundCheckDeferred = true
        watchForIdle()
        throw NSError(domain: "MeetingTranscriber.Updates", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Update check deferred while recording or transcribing."
        ])
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard mustDefer else {
            appState.beginTerminatingForUpdate()
            return false
        }
        Log.updates.notice("update \(item.displayVersionString, privacy: .public) waits for recording/transcription to finish")
        pendingInstall = installHandler
        pendingInstallVersion = item.displayVersionString
        watchForIdle()
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        appState.beginTerminatingForUpdate()
    }

    // MARK: – Idle tracking

    private func watchForIdle() {
        guard !isWatchingForIdle else { return }
        isWatchingForIdle = true
        withObservationTracking {
            _ = mustDefer
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isWatchingForIdle = false
                self.resumeIfIdle()
            }
        }
    }

    private func resumeIfIdle() {
        guard !mustDefer else {
            watchForIdle()
            return
        }
        if let install = pendingInstall {
            pendingInstall = nil
            pendingInstallVersion = nil
            backgroundCheckDeferred = false
            // Set before Sparkle quits the app so a call that starts now is
            // not auto-recorded and then cut by the relaunch.
            appState.beginTerminatingForUpdate()
            install()
        } else if backgroundCheckDeferred {
            backgroundCheckDeferred = false
            controller.updater.checkForUpdatesInBackground()
        }
    }
}
