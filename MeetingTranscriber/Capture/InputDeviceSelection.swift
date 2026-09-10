import Foundation
import CoreAudio

/// A CoreAudio device that can capture audio.
struct InputDevice: Hashable, Identifiable {
    /// Transient CoreAudio object ID — valid only for this boot.
    let id: AudioDeviceID
    /// Stable identifier; survives reboots and re-plugging. Persist this.
    let uid: String
    let name: String
}

enum InputDeviceSelection {
    /// The device to open for `preferredUID`, or nil to follow the system
    /// default. A stale UID (device unplugged since the last launch) also
    /// resolves to nil so recording still starts.
    static func resolve(preferredUID: String?, available: [InputDevice]) -> InputDevice? {
        guard let uid = preferredUID, !uid.isEmpty else { return nil }
        return available.first { $0.uid == uid }
    }
}
