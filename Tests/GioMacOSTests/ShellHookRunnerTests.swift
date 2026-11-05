import Foundation
@testable import GioMacOS
import XCTest

/// SB-01: the live hook runner: `/bin/sh -c`, off the caller's thread,
/// output discarded, killed after its timeout.
final class ShellHookRunnerTests: XCTestCase {
    private func run(_ command: String, environment: [String: String] = [:], timeout: TimeInterval = 5) -> HookRunResult? {
        let done = expectation(description: "hook finished")
        let box = ResultBox()
        let request = HookRunRequest(
            name: "test", command: command, environment: environment.merging(["PATH": "/usr/bin:/bin"]) { $1 },
            timeout: timeout
        )
        ShellHookRunner().run(request) { result in
            box.set(result)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: HookRunResult?

        func set(_ value: HookRunResult) {
            lock.withLock { stored = value }
        }

        var value: HookRunResult? {
            lock.withLock { stored }
        }
    }

    func testReportsTheExitStatus() {
        XCTAssertEqual(run("exit 3")?.status, .exited(3))
        XCTAssertEqual(run("echo noise; echo more >&2")?.status, .exited(0))
    }

    func testPassesTheEnvironment() {
        XCTAssertEqual(run("test \"$GIO_FOCUSED_WORKSPACE\" = 4", environment: ["GIO_FOCUSED_WORKSPACE": "4"])?.status, .exited(0))
        XCTAssertEqual(run("test \"$GIO_FOCUSED_WORKSPACE\" = 4", environment: ["GIO_FOCUSED_WORKSPACE": "5"])?.status, .exited(1))
    }

    func testKillsAHookPastItsTimeout() {
        let started = Date()
        let result = run("sleep 30", timeout: 0.2)
        XCTAssertEqual(result?.status, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertGreaterThanOrEqual(result?.milliseconds ?? 0, 150)
    }

    func testDoesNotBlockTheCaller() {
        let done = expectation(description: "hook finished")
        let started = Date()
        let request = HookRunRequest(name: "test", command: "sleep 0.3", environment: ["PATH": "/usr/bin:/bin"], timeout: 5)
        ShellHookRunner().run(request) { _ in
            done.fulfill()
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "run returns before the process ends")
        wait(for: [done], timeout: 5)
    }
}
