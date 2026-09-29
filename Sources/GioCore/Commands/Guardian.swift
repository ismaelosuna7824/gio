import Darwin
import Foundation

/// HD-07 guardian: a second process (the same executable, `--guardian <pid>`)
/// that Gio spawns with a pipe on the guardian's stdin. Gio writes `clean\n`
/// and closes the pipe once its own shutdown restored every window. If the
/// pipe ends without that message Gio died abruptly (SIGKILL, Xcode Stop,
/// Force Quit, a crash) and the guardian restores the parked windows.
public let guardianArgument = "--guardian"

/// The single message of the protocol.
public let guardianCleanMessage = "clean\n"

/// Pause after end-of-stream before the parent's liveness is judged.
public let guardianGrace: TimeInterval = 0.15

public func guardianArguments(parentPID: Int32) -> [String] {
    [guardianArgument, String(parentPID)]
}

/// The parent pid when `arguments` ask for guardian mode; nil otherwise or
/// when the pid is missing or not a positive integer.
public func parseGuardianLaunch(arguments: [String]) -> Int32? {
    guard let flag = arguments.firstIndex(of: guardianArgument),
          flag + 1 < arguments.count,
          let pid = Int32(arguments[flag + 1]), pid > 0 else {
        return nil
    }
    return pid
}

public enum GuardianOutcome: Equatable, Sendable {
    case cleanShutdown
    case parentDied
}

public enum GuardianAction: Equatable, Sendable {
    case exitQuietly
    case restore
    case exitParentAlive
}

/// Incremental reader of the pipe. Anything but a whole `clean\n` line is
/// ignored, so garbage behaves like silence and ends as abrupt death.
public struct GuardianMonitor: Sendable {
    private var buffer: [UInt8] = []
    private var clean = false

    public init() {}

    public mutating func consume(_ bytes: [UInt8]) -> GuardianOutcome? {
        buffer.append(contentsOf: bytes)
        let message = Array(guardianCleanMessage.utf8)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Array(buffer[...newline])
            buffer.removeSubrange(...newline)
            if line == message {
                clean = true
                return .cleanShutdown
            }
        }
        return clean ? .cleanShutdown : nil
    }

    public func endOfStream() -> GuardianOutcome {
        clean ? .cleanShutdown : .parentDied
    }
}

public func guardianAction(outcome: GuardianOutcome, parentAlive: Bool) -> GuardianAction {
    switch outcome {
    case .cleanShutdown: return .exitQuietly
    case .parentDied: return parentAlive ? .exitParentAlive : .restore
    }
}

/// `kill(pid, 0)`: alive unless the kernel says there is no such process.
public func isProcessAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

public enum GuardianResult: Equatable, Sendable {
    case cleanExit
    case restored
    case parentAlive
    case noAccessibility
}

/// The guardian's whole behaviour with its effects injected. `read` returns
/// the next chunk of the pipe, or nil at end-of-stream or on a read error.
public func runGuardianLoop(
    parentPID: Int32,
    read: () -> [UInt8]?,
    isParentAlive: (Int32) -> Bool,
    hasAccessibility: () -> Bool,
    sleep: (TimeInterval) -> Void,
    restore: () -> String,
    log: (String) -> Void
) -> GuardianResult {
    log("guardian started parent=\(parentPID)")
    var monitor = GuardianMonitor()
    var outcome: GuardianOutcome?
    while outcome == nil, let chunk = read() {
        outcome = monitor.consume(chunk)
    }
    let final = outcome ?? monitor.endOfStream()
    if final == .parentDied {
        sleep(guardianGrace)
    }
    switch guardianAction(outcome: final, parentAlive: final == .parentDied ? isParentAlive(parentPID) : true) {
    case .exitQuietly:
        log("guardian clean exit")
        return .cleanExit
    case .exitParentAlive:
        log("guardian exit: pipe closed but parent \(parentPID) is alive")
        return .parentAlive
    case .restore:
        guard hasAccessibility() else {
            log("guardian cannot restore: Accessibility not granted")
            return .noAccessibility
        }
        log("guardian restore \(restore())")
        return .restored
    }
}
