import Darwin
import Foundation

/// SB-01: one `[hooks]` run. `environment` is the whole environment the
/// shell gets (the caller merges the inherited one).
public struct HookRunRequest: Equatable, Sendable {
    public let name: String
    public let command: String
    public let environment: [String: String]
    public let timeout: TimeInterval

    public init(name: String, command: String, environment: [String: String], timeout: TimeInterval) {
        self.name = name
        self.command = command
        self.environment = environment
        self.timeout = timeout
    }
}

public enum HookRunStatus: Equatable, Sendable {
    case exited(Int32)
    /// Still running at the timeout: terminated (then killed).
    case timedOut
    case launchFailed
}

public struct HookRunResult: Equatable, Sendable {
    public let status: HookRunStatus
    public let milliseconds: Int

    public init(status: HookRunStatus, milliseconds: Int) {
        self.status = status
        self.milliseconds = milliseconds
    }
}

/// Runs a hook's shell command without blocking the caller; `completion`
/// runs once, on any thread.
public protocol HookRunner: AnyObject, Sendable {
    func run(_ request: HookRunRequest, completion: @escaping @Sendable (HookRunResult) -> Void)
}

/// The live runner: `/bin/sh -c <command>` spawned from a utility queue,
/// stdin, stdout and stderr on /dev/null, SIGTERM at the timeout and SIGKILL
/// one second later if it is still alive.
public final class ShellHookRunner: HookRunner, @unchecked Sendable {
    /// Grace between SIGTERM and SIGKILL.
    public static let killGrace: TimeInterval = 1

    private let queue = DispatchQueue(label: "gio.hooks", qos: .utility)

    public init() {}

    public func run(_ request: HookRunRequest, completion: @escaping @Sendable (HookRunResult) -> Void) {
        queue.async { [queue] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", request.command]
            process.environment = request.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let flight = HookProcessFlight()
            let started = DispatchTime.now()
            @Sendable func elapsed() -> Int {
                Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            }
            process.terminationHandler = { finished in
                let timedOut = flight.finish()
                completion(HookRunResult(
                    status: timedOut ? .timedOut : .exited(finished.terminationStatus), milliseconds: elapsed()
                ))
            }
            do {
                try process.run()
            } catch {
                completion(HookRunResult(status: .launchFailed, milliseconds: elapsed()))
                return
            }
            // The closures hold `process` until its timeout passed.
            queue.asyncAfter(deadline: .now() + request.timeout) {
                guard flight.expire() else {
                    return
                }
                kill(process.processIdentifier, SIGTERM)
                queue.asyncAfter(deadline: .now() + Self.killGrace) {
                    if flight.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }
}

/// Whether a hook process is still running and whether its timeout fired;
/// the termination handler and the timeout race on separate threads.
private final class HookProcessFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var timedOut = false

    var isRunning: Bool {
        lock.withLock { running }
    }

    /// The process ended: true when its timeout had fired.
    func finish() -> Bool {
        lock.withLock {
            running = false
            return timedOut
        }
    }

    /// The timeout fired: true when the process is still running (signal it).
    func expire() -> Bool {
        lock.withLock {
            guard running else {
                return false
            }
            timedOut = true
            return true
        }
    }
}
