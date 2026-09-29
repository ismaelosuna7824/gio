import XCTest
@testable import GioCore

/// HD-05: `gio restart` over IPC, and the lock wait a relaunched instance uses.
final class RestartTests: XCTestCase {
    func testHostedSessionAcknowledgesRestartWithoutDispatching() {
        var session = CommandSession()
        let response = dispatchIPC(["restart"], session: &session, restartAvailable: true)
        XCTAssertEqual(response, IPCResponse(ok: true, output: restartAcknowledgement))
    }

    func testWithoutAHostRestartKeepsTheDaemonMessage() {
        var session = CommandSession()
        let response = dispatchIPC(["restart"], session: &session)
        XCTAssertTrue(response.output?.contains("daemon") == true)
    }

    func testOnlyRestartRequestsARestart() {
        XCTAssertTrue(CLICommand.restart.requestsSessionRestart)
        for command: CLICommand in [.reload, .status, .help, .listWindows, .focus(.left)] {
            XCTAssertFalse(command.requestsSessionRestart)
        }
    }

    // MARK: Lock wait

    func testSucceedsImmediatelyWithoutSleeping() {
        var sleeps = 0
        XCTAssertTrue(acquiring(wait: .afterRestart, sleep: { _ in sleeps += 1 }, attempt: { true }))
        XCTAssertEqual(sleeps, 0)
    }

    func testRetriesUntilTheOldInstanceReleasesTheLock() {
        var attempts = 0
        var slept: [TimeInterval] = []
        let acquired = acquiring(wait: LockWait(attempts: 5, interval: 0.1), sleep: { slept.append($0) }) {
            attempts += 1
            return attempts == 3
        }
        XCTAssertTrue(acquired)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(slept, [0.1, 0.1])
    }

    func testGivesUpAfterTheLastAttemptWithoutASuperfluousSleep() {
        var attempts = 0
        var sleeps = 0
        let acquired = acquiring(wait: LockWait(attempts: 3, interval: 0.1), sleep: { _ in sleeps += 1 }) {
            attempts += 1
            return false
        }
        XCTAssertFalse(acquired)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleeps, 2)
    }

    func testOrdinaryLaunchDoesNotWait() {
        XCTAssertEqual(LockWait.forLaunch(arguments: ["Gio"]), .none)
        XCTAssertEqual(LockWait.none.attempts, 1)
    }

    func testRelaunchWaitsAFewSeconds() {
        let wait = LockWait.forLaunch(arguments: ["Gio", relaunchArgument])
        XCTAssertEqual(wait, .afterRestart)
        XCTAssertGreaterThanOrEqual(Double(wait.attempts) * wait.interval, 3)
    }

    func testRealLockIsAcquiredOnceTheHolderReleases() {
        let path = NSTemporaryDirectory() + "gio-restart-\(UUID().uuidString).lock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let holder = SingleInstanceLock()
        XCTAssertTrue(holder.acquire(path: path))
        let waiter = SingleInstanceLock()
        XCTAssertFalse(waiter.acquire(path: path, wait: .none))
        var released = false
        let acquired = waiter.acquire(
            path: path, wait: LockWait(attempts: 4, interval: 0), sleep: { _ in
                if !released {
                    released = true
                    holder.release()
                }
            }
        )
        XCTAssertTrue(acquired)
    }
}
