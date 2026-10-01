import CoreAudio
import Darwin
import Foundation

/// Detects native voice calls (WhatsApp, iPhone calls via Continuity, Signal,
/// native Zoom/Teams…) by watching which processes CoreAudio reports as
/// capturing the mic and playing audio. Needs no TCC permission and never
/// talks to the call apps themselves. Browser meetings stay with
/// `MeetingDetector`; browsers are not on the call-app list.
@MainActor
final class CallDetector {
    typealias ClientProvider = () -> [AudioClientSnapshot]

    private let clients: ClientProvider
    private let pollIntervalNanoseconds: UInt64
    private var tracker: CallActivityTracker
    private var pollTask: Task<Void, Never>?

    var onCallDetected: ((DetectedMeeting) -> Void)?

    init(
        tracker: CallActivityTracker = CallActivityTracker(),
        pollIntervalNanoseconds: UInt64 = 1_000_000_000,
        clients: @escaping ClientProvider = CoreAudioClients.snapshot
    ) {
        self.tracker = tracker
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.clients = clients
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pollOnce()
                do {
                    try await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() {
        let snapshot = clients()
        for call in tracker.update(clients: snapshot, at: Date()) {
            Log.callDetection.notice("call detected: \(call.app.name, privacy: .public)")
            onCallDetected?(DetectedMeeting(
                title: "\(call.app.name) call",
                platform: call.app.name,
                url: "call://\(call.app.windowBundleID)/\(Int(call.startedAt.timeIntervalSince1970))",
                detectedAt: call.startedAt,
                browserBundleID: call.app.windowBundleID,
                tapProcessNames: call.app.tapExecutableNames
            ))
        }
    }
}

/// Reads CoreAudio's per-process client list (macOS 14.4+).
enum CoreAudioClients {
    static func snapshot() -> [AudioClientSnapshot] {
        processObjects().compactMap { object in
            let input = uint32(object, kAudioProcessPropertyIsRunningInput) != 0
            let output = uint32(object, kAudioProcessPropertyIsRunningOutput) != 0
            guard input || output else { return nil }
            let pid = pid(object)
            return AudioClientSnapshot(
                pid: pid,
                bundleID: bundleID(object),
                executablePath: executablePath(pid),
                isRunningInput: input,
                isRunningOutput: output
            )
        }
    }

    /// Process objects whose executable is one of `executableNames`.
    static func processObjects(executableNames: [String]) -> [AudioObjectID] {
        processObjects().filter { object in
            let name = (executablePath(pid(object)) as NSString).lastPathComponent
            return executableNames.contains(name)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func pid(_ object: AudioObjectID) -> Int32 {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func bundleID(_ object: AudioObjectID) -> String {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue()
        else { return "" }
        return string as String
    }

    private static func executablePath(_ pid: Int32) -> String {
        guard pid > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }
}
