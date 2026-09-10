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

    /// UID to record from: the session override from the record card when
    /// set, else the persisted preference from Settings. Empty strings count
    /// as unset. Nil means follow the system default.
    static func effectiveUID(sessionOverride: String?, preferred: String?) -> String? {
        if let uid = sessionOverride, !uid.isEmpty { return uid }
        if let uid = preferred, !uid.isEmpty { return uid }
        return nil
    }

    /// Title of the record card's first menu item: names the preferred mic
    /// when it is connected so the user can see what "default" will resolve
    /// to, else the plain system default.
    static func defaultLabel(preferred: String?, available: [InputDevice]) -> String {
        if let device = resolve(preferredUID: preferred, available: available) {
            return "Default (\(device.name))"
        }
        return "System Default"
    }
}
