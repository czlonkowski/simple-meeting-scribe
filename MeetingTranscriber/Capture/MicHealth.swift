import Foundation

/// Live health of mic capture, surfaced while recording.
enum MicStatus: Equatable {
    case ok
    /// The engine is being rebuilt, or buffers stopped arriving;
    /// `silentSeconds` is how long the mic stem has had no real audio.
    case recovering(silentSeconds: Int)
}

/// Keeps the voice stem on the recording's timeline across capture gaps.
///
/// Stems are append-only and merged by sample count, so time the mic did not
/// deliver (an engine rebuild, a stall) must be written as silence or every
/// later mic segment lands early. The gap is measured from each buffer's host
/// time — monotonic across engine rebuilds — not from when the callback ran,
/// so delivery jitter below `tolerance` is never mistaken for missing audio.
struct MicTimeline {
    let sampleRate: Double
    var tolerance: TimeInterval = 0.25

    private var epoch: TimeInterval?
    private var framesWritten = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Frames of silence to write before a buffer whose audio starts at
    /// `hostSeconds`. The first buffer anchors the timeline.
    mutating func padding(beforeBufferAt hostSeconds: TimeInterval) -> Int {
        guard let epoch else {
            epoch = hostSeconds
            return 0
        }
        let expected = Int(((hostSeconds - epoch) * sampleRate).rounded())
        let gap = expected - framesWritten
        return gap > Int(tolerance * sampleRate) ? gap : 0
    }

    mutating func didWrite(_ frames: Int) {
        framesWritten += frames
    }
}

/// When to rebuild the mic engine.
///
/// A rebuild re-selects the preferred device, which itself posts another
/// AVAudioEngine configuration change; rebuilding for every notification made
/// AirPods switching turn into dozens of rebuilds ~140 ms apart with no audio
/// in between. So a (debounced) notification only leads to a rebuild when the
/// mic is demonstrably not working.
enum MicHealth {
    /// Notifications within this window are handled once.
    static let debounce: TimeInterval = 0.3
    /// Buffers this recent mean the engine survived the change.
    static let freshBufferWindow: TimeInterval = 0.5
    /// No buffers for this long (on an engine at least this old) is a stall.
    static let stallThreshold: TimeInterval = 3

    static func needsRebuild(engineRunning: Bool,
                             secondsSinceLastBuffer: TimeInterval?,
                             onPreferredDevice: Bool) -> Bool {
        guard engineRunning, onPreferredDevice,
              let sinceBuffer = secondsSinceLastBuffer else { return true }
        return sinceBuffer > freshBufferWindow
    }

    static func isStalled(secondsSinceEngineStart: TimeInterval,
                          secondsSinceLastBuffer: TimeInterval?) -> Bool {
        guard secondsSinceEngineStart >= stallThreshold else { return false }
        return (secondsSinceLastBuffer ?? .infinity) >= stallThreshold
    }

    /// 0.5, 1, 2, then every 4 s — for as long as the recording runs.
    static func retryDelay(afterFailedAttempts attempts: Int) -> TimeInterval {
        min(4, 0.5 * pow(2, Double(max(attempts, 1) - 1)))
    }
}
