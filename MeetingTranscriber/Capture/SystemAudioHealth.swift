import Foundation

/// Live state of system-audio capture, surfaced while recording so a stream
/// that has gone deaf can't stay invisible.
enum SystemAudioStatus: Equatable {
    case ok
    /// Nothing but digital silence for `seconds`. The remote party may not be
    /// reaching the recording at all.
    case silent(seconds: Int)
    /// A recovery attempt (filter refresh or stream rebuild) is in flight.
    case recovering
}

/// Decides when a digitally-silent system stem means the ScreenCaptureKit
/// capture has gone deaf, and how hard to try to recover.
///
/// Why this exists: an `SCStream` can keep delivering audio buffers at full
/// rate while silently dropping one application's audio — no error, no
/// `didStopWithError`, no change in stream state. On 2026-08-12 a 3h08m meeting
/// lost ~2h of the remote participants that way: buffers arrived for the whole
/// session and every sample in them was zero. The stream looked perfectly
/// healthy from the app's side, so nothing recovered it and nothing warned.
///
/// Escalation ladder, driven purely by how long the stem has been exactly zero:
///   `refreshAfter`             → refresh the content filter (gapless)
///   `+ restartAfter` more      → tear the stream down and rebuild it
/// then the cycle repeats until `maxRecoveryAttempts` is spent, so a genuinely
/// quiet meeting can't rebuild the stream forever.
struct SystemAudioHealth: Equatable {
    enum Action: Equatable {
        case none
        /// Rebuild the `SCContentFilter` from freshly fetched shareable content
        /// and apply it in place via `updateContentFilter` — no teardown, so no
        /// gap in the stem.
        case refreshFilter
        /// Stop and restart the whole stream. This leaves a real gap, so the
        /// caller must pad the stem for the elapsed time.
        case restartStream
    }

    /// Seconds of exact-zero audio before the first (cheap) recovery attempt.
    var refreshAfter: TimeInterval = 45
    /// Further seconds of silence after a refresh before escalating to a rebuild.
    var restartAfter: TimeInterval = 30
    /// Seconds of real audio that must elapse before a recovered stream earns a
    /// fresh attempt budget. Requiring it to be *sustained* stops a flickering
    /// stream from looping recoveries forever.
    var healthyResetAfter: TimeInterval = 60
    /// Recovery attempts allowed before we stop touching the stream.
    var maxRecoveryAttempts: Int = 8

    private(set) var silentSeconds: TimeInterval = 0
    private(set) var recoveryAttempts: Int = 0
    private var healthySeconds: TimeInterval = 0
    private var didRefreshThisCycle = false

    // Spelled out rather than synthesized: the private counters above would
    // make the memberwise init private, and the thresholds need to be tunable
    // from tests.
    init(refreshAfter: TimeInterval = 45,
         restartAfter: TimeInterval = 30,
         healthyResetAfter: TimeInterval = 60,
         maxRecoveryAttempts: Int = 8) {
        self.refreshAfter = refreshAfter
        self.restartAfter = restartAfter
        self.healthyResetAfter = healthyResetAfter
        self.maxRecoveryAttempts = maxRecoveryAttempts
    }

    /// True once the stem has been silent long enough that we would act on it —
    /// the same bar the UI warns at, so the warning and the recovery agree.
    var isConcerning: Bool { silentSeconds >= refreshAfter }

    /// Feed every converted buffer.
    ///
    /// `isSilent` must be an exact-zero test (max-abs == 0), never an RMS
    /// threshold: a real capture of a quiet room still carries a noise floor,
    /// while an app dropped by the capture produces literal zeros. That
    /// distinction is the entire signal.
    mutating func ingest(frames: Int, sampleRate: Double, isSilent: Bool) -> Action {
        guard frames > 0, sampleRate > 0 else { return .none }
        let seconds = Double(frames) / sampleRate

        guard isSilent else {
            silentSeconds = 0
            didRefreshThisCycle = false
            healthySeconds += seconds
            if healthySeconds >= healthyResetAfter { recoveryAttempts = 0 }
            return .none
        }

        healthySeconds = 0
        silentSeconds += seconds
        guard recoveryAttempts < maxRecoveryAttempts else { return .none }

        if !didRefreshThisCycle {
            guard silentSeconds >= refreshAfter else { return .none }
            didRefreshThisCycle = true
            recoveryAttempts += 1
            return .refreshFilter
        }

        guard silentSeconds >= refreshAfter + restartAfter else { return .none }
        // Escalated as far as the ladder goes. Start a fresh cycle so a stream
        // that is still deaf gets refreshed again rather than left alone.
        silentSeconds = 0
        didRefreshThisCycle = false
        recoveryAttempts += 1
        return .restartStream
    }

    /// Audio came back, or the stream was rebuilt — forget the silent run.
    /// Deliberately keeps `recoveryAttempts`: only sustained real audio (see
    /// `healthyResetAfter`) proves a recovery actually worked.
    mutating func reset() {
        silentSeconds = 0
        didRefreshThisCycle = false
    }

    /// What the UI should show for the current run of silence. Quantized to
    /// 5-second steps so the status doesn't churn on every buffer.
    var status: SystemAudioStatus {
        isConcerning ? .silent(seconds: Int(silentSeconds / 5) * 5) : .ok
    }
}
