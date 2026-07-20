import Darwin
import Foundation

struct BrowserDescriptor: Hashable, Sendable {
    let name: String
    let bundleID: String
    let scriptSource: String
}

enum BrowserURLQueryResult: Equatable, Sendable {
    case url(String)
    case noURL
    case timedOut
    case failed(String)
    case cancelled
}

protocol BrowserURLQuerying: Sendable {
    func activeURL(for browser: BrowserDescriptor) async -> BrowserURLQueryResult
}

enum ScriptProcessResult: Equatable, Sendable {
    case output(String)
    case timedOut
    case failed(String)
    case cancelled
}

protocol ScriptProcessRunning: Sendable {
    func run(script: String, timeoutNanoseconds: UInt64) async -> ScriptProcessResult
}

struct OSAScriptBrowserURLQuery: BrowserURLQuerying {
    private let runner: any ScriptProcessRunning
    private let appleEventTimeoutSeconds: Int
    private let processTimeoutNanoseconds: UInt64

    init(
        runner: any ScriptProcessRunning = ProcessScriptRunner(),
        appleEventTimeoutSeconds: Int = 1,
        processTimeoutNanoseconds: UInt64 = 1_500_000_000
    ) {
        self.runner = runner
        self.appleEventTimeoutSeconds = appleEventTimeoutSeconds
        self.processTimeoutNanoseconds = processTimeoutNanoseconds
    }

    func activeURL(for browser: BrowserDescriptor) async -> BrowserURLQueryResult {
        let source = """
        with timeout of \(appleEventTimeoutSeconds) seconds
        \(browser.scriptSource)
        end timeout
        """
        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = await runner.run(script: source, timeoutNanoseconds: processTimeoutNanoseconds)
        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        Log.browserDetection.debug(
            "query \(browser.name, privacy: .public) finished in \(elapsedMilliseconds, format: .fixed(precision: 1), privacy: .public)ms"
        )

        switch result {
        case .output(let output):
            let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? .noURL : .url(url)
        case .timedOut:
            return .timedOut
        case .failed(let message):
            return .failed(message)
        case .cancelled:
            return .cancelled
        }
    }
}

struct ProcessScriptRunner: ScriptProcessRunning {
    fileprivate static let forceKillDelayNanoseconds: UInt64 = 250_000_000
    private let executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
        self.executableURL = executableURL
    }

    func run(script: String, timeoutNanoseconds: UInt64) async -> ScriptProcessResult {
        let box = RunningProcessBox()

        return await withTaskCancellationHandler {
            await withTaskGroup(of: ScriptProcessResult.self) { group in
                group.addTask {
                    await Self.execute(
                        executableURL: executableURL,
                        script: script,
                        box: box
                    )
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return .cancelled
                    }
                    box.cancel()
                    return .timedOut
                }

                let first = await group.next() ?? .cancelled
                group.cancelAll()
                return first
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func execute(
        executableURL: URL,
        script: String,
        box: RunningProcessBox
    ) async -> ScriptProcessResult {
        if Task.isCancelled { return .cancelled }

        return await withCheckedContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["-e", script]
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { completed in
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let wasCancelled = box.cancellationRequested
                box.clear(completed)

                if completed.terminationStatus == 0 {
                    continuation.resume(returning: .output(String(decoding: output, as: UTF8.self)))
                } else if wasCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    let message = String(decoding: errorOutput, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: .failed(message))
                }
            }

            do {
                guard try box.launch(process) else {
                    continuation.resume(returning: .cancelled)
                    return
                }
            } catch {
                box.clear(process)
                continuation.resume(returning: .failed(error.localizedDescription))
            }
        }
    }
}

private final class RunningProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false
    private var scheduledForceKill = false

    func launch(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.process = process
        do {
            try process.run()
            return true
        } catch {
            self.process = nil
            throw error
        }
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    var cancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func cancel() {
        let processToTerminate: Process?
        let shouldScheduleForceKill: Bool

        lock.lock()
        isCancelled = true
        processToTerminate = process
        shouldScheduleForceKill = !scheduledForceKill
        scheduledForceKill = true
        lock.unlock()

        if processToTerminate?.isRunning == true {
            processToTerminate?.terminate()
        }

        guard shouldScheduleForceKill else { return }
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: ProcessScriptRunner.forceKillDelayNanoseconds)
            self?.forceKillIfNeeded()
        }
    }

    private func forceKillIfNeeded() {
        lock.lock()
        let runningProcess = process
        lock.unlock()

        guard let runningProcess, runningProcess.isRunning else { return }
        kill(runningProcess.processIdentifier, SIGKILL)
    }
}
