import Foundation

/// First-run decisions: which engine a launch starts on, and whether the
/// setup assistant should open.
enum SetupDefaults {
    /// The engine a launch starts on. A choice saved by the setup assistant or
    /// Settings wins. Without one, a cloud engine is used only when its key is
    /// configured, so a fresh install never starts on an engine that can't run.
    static func initialEngine(stored: WhisperModel?, hasMAIKey: Bool, hasScribeKey: Bool) -> WhisperModel {
        if let stored { return stored }
        if hasMAIKey { return .maiTranscribe2 }
        if hasScribeKey { return .scribeV2 }
        return .largeV3Turbo
    }

    /// Open the assistant on a fresh install only. Anyone who already recorded
    /// or added a cloud key set the app up before the assistant existed.
    static func shouldShowSetup(completed: Bool, hasTranscripts: Bool, hasCloudKeys: Bool) -> Bool {
        !completed && !hasTranscripts && !hasCloudKeys
    }

    /// The cloud engine to make the default, given the keys entered: MAI when
    /// its key and endpoint are set, otherwise Scribe, otherwise none.
    static func cloudEngine(hasMAIKey: Bool, hasScribeKey: Bool) -> WhisperModel? {
        if hasMAIKey { return .maiTranscribe2 }
        if hasScribeKey { return .scribeV2 }
        return nil
    }
}
