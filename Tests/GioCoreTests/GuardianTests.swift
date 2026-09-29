import XCTest
@testable import GioCore

/// HD-07: the guardian's pipe protocol, decision table and launch arguments.
final class GuardianTests: XCTestCase {
    // MARK: Arguments

    func testParsesGuardianPid() {
        XCTAssertEqual(parseGuardianLaunch(arguments: ["Gio", "--guardian", "123"]), 123)
    }

    func testRejectsMissingOrInvalidPid() {
        XCTAssertNil(parseGuardianLaunch(arguments: ["Gio"]))
        XCTAssertNil(parseGuardianLaunch(arguments: ["Gio", "--guardian"]))
        XCTAssertNil(parseGuardianLaunch(arguments: ["Gio", "--guardian", "abc"]))
        XCTAssertNil(parseGuardianLaunch(arguments: ["Gio", "--guardian", "0"]))
        XCTAssertNil(parseGuardianLaunch(arguments: ["Gio", "--guardian", "-5"]))
    }

    func testGuardianArgumentsRoundTrip() {
        XCTAssertEqual(parseGuardianLaunch(arguments: ["x"] + guardianArguments(parentPID: 77)), 77)
    }

    // MARK: Protocol

    func testCleanMessageEndsAsCleanShutdown() {
        var monitor = GuardianMonitor()
        XCTAssertEqual(monitor.consume(Array("clean\n".utf8)), .cleanShutdown)
    }

    func testCleanMessageSplitAcrossReads() {
        var monitor = GuardianMonitor()
        XCTAssertNil(monitor.consume(Array("cle".utf8)))
        XCTAssertEqual(monitor.consume(Array("an\n".utf8)), .cleanShutdown)
    }

    func testEndOfStreamWithoutCleanIsAbruptDeath() {
        let monitor = GuardianMonitor()
        XCTAssertEqual(monitor.endOfStream(), .parentDied)
    }

    func testGarbageIsTreatedAsNoMessage() {
        var monitor = GuardianMonitor()
        XCTAssertNil(monitor.consume(Array("hello\n".utf8)))
        XCTAssertNil(monitor.consume([0xFF, 0x00, 0x0A]))
        XCTAssertEqual(monitor.endOfStream(), .parentDied)
    }

    func testEndOfStreamAfterCleanStaysClean() {
        var monitor = GuardianMonitor()
        _ = monitor.consume(Array("clean\n".utf8))
        XCTAssertEqual(monitor.endOfStream(), .cleanShutdown)
    }

    // MARK: Decision

    func testDecisionTable() {
        XCTAssertEqual(guardianAction(outcome: .cleanShutdown, parentAlive: true), .exitQuietly)
        XCTAssertEqual(guardianAction(outcome: .cleanShutdown, parentAlive: false), .exitQuietly)
        XCTAssertEqual(guardianAction(outcome: .parentDied, parentAlive: false), .restore)
        XCTAssertEqual(guardianAction(outcome: .parentDied, parentAlive: true), .exitParentAlive)
    }

    // MARK: Loop

    private func run(
        chunks: [[UInt8]], alive: Bool, accessibility: Bool = true
    ) -> (result: GuardianResult, restores: Int, sleeps: [TimeInterval], logs: [String]) {
        var pending = chunks
        var restores = 0
        var sleeps: [TimeInterval] = []
        var logs: [String] = []
        let result = runGuardianLoop(
            parentPID: 9,
            read: { pending.isEmpty ? nil : pending.removeFirst() },
            isParentAlive: { _ in alive },
            hasAccessibility: { accessibility },
            sleep: { sleeps.append($0) },
            restore: { restores += 1; return "applied=2 failed=0" },
            log: { logs.append($0) }
        )
        return (result, restores, sleeps, logs)
    }

    func testCleanShutdownNeverRestores() {
        let outcome = run(chunks: [Array("clean\n".utf8)], alive: true)
        XCTAssertEqual(outcome.result, .cleanExit)
        XCTAssertEqual(outcome.restores, 0)
        XCTAssertTrue(outcome.logs.contains("guardian started parent=9"))
        XCTAssertTrue(outcome.logs.contains("guardian clean exit"))
    }

    func testEndOfStreamWithDeadParentRestoresAfterAGrace() {
        let outcome = run(chunks: [], alive: false)
        XCTAssertEqual(outcome.result, .restored)
        XCTAssertEqual(outcome.restores, 1)
        XCTAssertEqual(outcome.sleeps, [guardianGrace])
        XCTAssertTrue(outcome.logs.contains("guardian restore applied=2 failed=0"))
    }

    func testEndOfStreamWithLiveParentDoesNothing() {
        let outcome = run(chunks: [], alive: true)
        XCTAssertEqual(outcome.result, .parentAlive)
        XCTAssertEqual(outcome.restores, 0)
    }

    func testWithoutAccessibilityItLogsAndExits() {
        let outcome = run(chunks: [], alive: false, accessibility: false)
        XCTAssertEqual(outcome.result, .noAccessibility)
        XCTAssertEqual(outcome.restores, 0)
    }

    // MARK: Liveness

    func testProcessLiveness() {
        XCTAssertTrue(isProcessAlive(getpid()))
        XCTAssertFalse(isProcessAlive(Int32.max))
    }
}
