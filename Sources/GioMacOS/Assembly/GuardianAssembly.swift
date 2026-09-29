import Darwin
import Foundation
import GioCore

/// Guardian side (`Gio --guardian <pid>`): blocks reading stdin, then applies
/// the protocol in GioCore. Returns the process exit status. Never touches
/// the lock, the socket or any window unless Gio died without saying `clean`.
public func runGuardianProcess(parentPID: Int32) -> Int32 {
    // Inherited descriptors (lock, socket) must not outlive Gio through us.
    for descriptor in 3..<256 {
        close(Int32(descriptor))
    }
    let result = runGuardianLoop(
        parentPID: parentPID,
        read: {
            var bytes = [UInt8](repeating: 0, count: 64)
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            return count > 0 ? Array(bytes[0..<count]) : nil
        },
        isParentAlive: isProcessAlive,
        hasAccessibility: hasAXPermission,
        sleep: { Thread.sleep(forTimeInterval: $0) },
        restore: {
            do {
                let report = try runRestoreOffscreen()
                return "applied=\(report.restored) failed=\(report.failed) scanned=\(report.scanned)"
            } catch {
                return "applied=0 failed=? error=\(error)"
            }
        },
        log: { GioLog.record(.info, $0) }
    )
    return result == .restored || result == .cleanExit || result == .parentAlive ? 0 : 1
}

/// Gio side: the running guardian and the pipe that feeds it.
public final class GuardianHandle: @unchecked Sendable {
    private let process: Process
    private let pipe: Pipe
    private let lock = NSLock()
    private var closed = false

    init(process: Process, pipe: Pipe) {
        self.process = process
        self.pipe = pipe
    }

    /// Tell the guardian the shutdown finished: write `clean`, close the pipe.
    /// Idempotent.
    public func signalClean() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            return
        }
        closed = true
        try? pipe.fileHandleForWriting.write(contentsOf: Data(guardianCleanMessage.utf8))
        try? pipe.fileHandleForWriting.close()
    }
}

/// Re-executes this same executable in guardian mode (same bundle and code
/// signature, so the Accessibility grant applies). Nil when it cannot start;
/// Gio keeps working without it.
public func spawnGuardian(
    executable: URL? = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
) -> GuardianHandle? {
    guard let executable else {
        return nil
    }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = guardianArguments(parentPID: ProcessInfo.processInfo.processIdentifier)
    process.standardInput = pipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        GioLog.record(.warn, "guardian could not start: \(error)")
        return nil
    }
    try? pipe.fileHandleForReading.close()
    return GuardianHandle(process: process, pipe: pipe)
}
