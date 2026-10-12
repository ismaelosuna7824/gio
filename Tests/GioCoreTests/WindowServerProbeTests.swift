import XCTest
@testable import GioCore

/// PF-P: the runtime probe judges SkyLight from real flights without being
/// fooled by a late readback, a move too small to tell from the start, a
/// readback in another coordinate space or evidence from another moment, and
/// a failure turns the transport off only until a later retry.
final class WindowServerProbeTests: XCTestCase {
    private let start = CGRect(x: 100, y: 47, width: 888, height: 1114)
    private let tick: TimeInterval = 1.0 / 120
    private let window: UInt32 = 9

    private typealias Placed = [(at: TimeInterval, frame: CGRect)]

    /// One window's flight: every tick observes first (like
    /// `submitWindowServerMotion`), then commits `step` pt further. `drawn`
    /// says what the WindowServer reports at a time, given what was placed.
    /// Stops at the first failure (the transport is off from then on).
    private func fly(
        _ probe: inout WindowServerProbe, ticks: Int, from t0: TimeInterval = 0, origin: CGRect? = nil,
        step: CGFloat = -12, drawn: (TimeInterval, Placed) -> CGRect?
    ) -> [WindowServerProbeVerdict] {
        var verdicts: [WindowServerProbeVerdict] = []
        var placed: Placed = []
        var last = origin ?? start
        for index in 0..<ticks {
            let now = t0 + Double(index) * tick
            if probe.observationTargets().contains(window) {
                let frame = drawn(now, placed)
                if let verdict = probe.observe(frame.map { [window: $0] } ?? [:], at: now) {
                    verdicts.append(verdict)
                    if verdict.result == .failed {
                        return verdicts
                    }
                }
            }
            guard probe.isTrialRunning else {
                continue
            }
            let to = last.offsetBy(dx: step, dy: 0)
            probe.moved(windowID: window, from: last, to: to, at: now)
            placed.append((now, to))
            last = to
        }
        return verdicts
    }

    /// A WindowServer that shows each commit `latency` seconds after it.
    private func working(latency: TimeInterval, origin: CGRect? = nil, offset: CGFloat = 0)
        -> (TimeInterval, Placed) -> CGRect?
    {
        let base = origin ?? start
        return { now, placed in
            let shown = placed.last(where: { $0.at <= now - latency })?.frame ?? base
            return shown.offsetBy(dx: 0, dy: offset)
        }
    }

    /// A WindowServer that never takes the moves.
    private func refused(origin: CGRect? = nil, offset: CGFloat = 0) -> (TimeInterval, Placed) -> CGRect? {
        let base = origin ?? start
        return { _, _ in base.offsetBy(dx: 0, dy: offset) }
    }

    // MARK: Latency

    func testAWindowServerThatShowsTheMovesThreeTicksLateIsVerified() {
        var probe = WindowServerProbe()
        let verdicts = fly(&probe, ticks: 20, drawn: working(latency: 0.026))
        XCTAssertEqual(verdicts.map(\.result), [.verified])
        XCTAssertEqual(probe.state, .verified)
    }

    func testAReadbackLateByMoreThanTheTickBudgetButWithinTheAllowanceIsVerified() {
        var probe = WindowServerProbe()
        let verdicts = fly(&probe, ticks: 30, drawn: working(latency: 0.045))
        XCTAssertEqual(verdicts.map(\.result), [.verified])
    }

    func testAWindowServerThatIgnoresTheMovesFailsOnlyAfterTheReadbackAllowance() throws {
        var probe = WindowServerProbe()
        let verdicts = fly(&probe, ticks: 60, drawn: refused())
        let verdict = try XCTUnwrap(verdicts.last)
        XCTAssertEqual(verdicts.map(\.result), [.failed])
        XCTAssertGreaterThanOrEqual(verdict.sinceFirstMove, WindowServerProbe.readbackAllowance)
        XCTAssertLessThan(verdict.sinceFirstMove, 0.1, "a refused transport freezes one flight briefly")
        XCTAssertEqual(probe.state, .failed)
        XCTAssertTrue(probe.observationTargets().isEmpty)
        // Evidence for the log: where it started, where it is drawn, what Gio committed last.
        XCTAssertTrue(verdict.logLine.hasPrefix("skylight probe result=failed trial=1 window=9 start=(100,47) drawn=(100,47) lastCommit=("), verdict.logLine)
        XCTAssertTrue(verdict.logLine.contains(" retryInS=2"), verdict.logLine)
    }

    // MARK: What counts as proof

    func testAMoveNoFartherThanTheSlackDoesNotVerify() {
        var probe = WindowServerProbe()
        // Two-point steps: the first commit is within the slack of the start,
        // where a WindowServer that ignores the moves still draws the window.
        let verdicts = fly(&probe, ticks: 4, step: -2, drawn: refused())
        XCTAssertTrue(verdicts.isEmpty)
        XCTAssertEqual(probe.state, .unverified)
    }

    func testAReadbackInAnotherCoordinateSpaceStillVerifies() throws {
        var probe = WindowServerProbe()
        let verdicts = fly(&probe, ticks: 10, drawn: working(latency: 0, offset: 30))
        let verdict = try XCTUnwrap(verdicts.first)
        XCTAssertEqual(verdict.result, .verified)
        XCTAssertTrue(verdict.logLine.contains(" match=translation"), verdict.logLine)
    }

    func testAReadbackInAnotherCoordinateSpaceStillFails() {
        var probe = WindowServerProbe()
        let verdicts = fly(&probe, ticks: 60, drawn: refused(offset: 30))
        XCTAssertEqual(verdicts.map(\.result), [.failed])
    }

    func testAMoveTheWindowServerShowsAtTheCommittedFrameVerifiesDirectly() throws {
        var probe = WindowServerProbe()
        let verdict = try XCTUnwrap(fly(&probe, ticks: 5, drawn: working(latency: 0)).first)
        XCTAssertEqual(
            verdict.logLine, "skylight probe result=verified trial=1 window=9 match=direct sinceFirstMoveMs=8"
        )
    }

    func testAReadbackThatMovesResetsTheStuckCount() {
        var probe = WindowServerProbe()
        // Ignored until well past the allowance (two stuck looks), then one
        // readback elsewhere (the app put it somewhere), then ignored again
        // (two more): without the reset the third stuck look would fail it.
        // Stuck looks at ticks 7 and 8 (the commit of tick 1, made after the
        // first look, is 50 ms old at tick 7), elsewhere at 9, stuck at 10, 11.
        let verdicts = fly(&probe, ticks: 12) { now, _ in
            abs(now - 9 * self.tick) < 0.001 ? self.start.offsetBy(dx: 0, dy: 300) : self.start
        }
        XCTAssertTrue(verdicts.isEmpty, "two stuck looks, a move, two stuck looks: no verdict yet")
        XCTAssertEqual(probe.state, .unverified)
    }

    // MARK: Evidence from another moment

    func testAWindowMovedOutsideItsFlightIsForgotten() {
        var probe = WindowServerProbe()
        _ = fly(&probe, ticks: 3, drawn: refused())
        let committed = start.offsetBy(dx: -36, dy: 0)
        // The final pass's Accessibility write puts the window at the last
        // committed frame; the reconciler tells the probe.
        probe.forget([window])
        // The next flight starts there; the window being drawn there proves nothing.
        let verdicts = fly(&probe, ticks: 3, from: 1, origin: committed, drawn: refused(origin: committed))
        XCTAssertTrue(verdicts.isEmpty)
        XCTAssertEqual(probe.state, .unverified)
    }

    func testStuckLooksFromAnEarlierFlightDoNotCount() {
        var probe = WindowServerProbe()
        // Nine ticks: past the allowance, two stuck looks (ticks 7 and 8).
        XCTAssertTrue(fly(&probe, ticks: 9, drawn: refused()).isEmpty)
        // A second of rest, then a short flight from the same place: it
        // starts over instead of finishing the old count.
        XCTAssertTrue(fly(&probe, ticks: 3, from: 1, drawn: refused()).isEmpty)
        XCTAssertEqual(probe.state, .unverified)
    }

    // MARK: Retry

    func testAFailedProbeRetriesLaterAndBacksOffAfterASecondFailure() throws {
        var probe = WindowServerProbe()
        let first = try XCTUnwrap(fly(&probe, ticks: 60, drawn: refused()).last)
        let failedAt = first.sinceFirstMove
        XCTAssertEqual(first.retryAfter, 2)
        probe.refresh(at: failedAt + 1.9)
        XCTAssertEqual(probe.state, .failed)
        XCTAssertFalse(probe.isTrialRunning)
        probe.refresh(at: failedAt + 2.0)
        XCTAssertEqual(probe.state, .retrying)
        XCTAssertEqual(probe.trial, 2)

        let second = try XCTUnwrap(fly(&probe, ticks: 60, from: 10, drawn: refused()).last)
        XCTAssertEqual(second.result, .failed)
        XCTAssertEqual(second.trial, 2)
        XCTAssertEqual(second.retryAfter, 600)
        XCTAssertTrue(second.logLine.contains(" retryInS=600"), second.logLine)
        probe.refresh(at: 10 + 599)
        XCTAssertEqual(probe.state, .failed)
        probe.refresh(at: 10 + 601)
        XCTAssertEqual(probe.state, .retrying)

        // A trial that verifies ends the story.
        let third = fly(&probe, ticks: 10, from: 700, drawn: working(latency: 0))
        XCTAssertEqual(third.map(\.result), [.verified])
        XCTAssertEqual(probe.state, .verified)
    }

    func testStatusSaysWhenTheProbeRetries() {
        XCTAssertEqual(
            windowServerTransportStatus(enabled: true, missingSymbols: [], probe: .retrying).logLine,
            "skylight available=true reason=probe-retrying"
        )
    }
}
