import XCTest
@testable import GioCore

/// FI-05: what the WindowServer draws can disagree with what Accessibility
/// reports. These pure rules match managed windows to WindowServer entries,
/// decide a mismatch, plan the minimal corrective nudge and bound it.
final class RenderVerificationTests: XCTestCase {
    private func id(_ pid: pid_t, _ element: UInt64 = 1) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private let frame = CGRect(x: 100, y: 200, width: 600, height: 400)

    // MARK: Coordinates

    func testWindowServerBoundsConvertToCocoaWithTheSameFlipAsAX() {
        // CG global: top-left origin. Display 1000 high, window 400 high at
        // top y=100 -> Cocoa bottom y = 1000 - 100 - 400 = 500.
        let cocoa = cocoaFrame(fromWindowServer: CGRect(x: 30, y: 100, width: 600, height: 400), displayHeight: 1000)
        XCTAssertEqual(cocoa, CGRect(x: 30, y: 500, width: 600, height: 400))
    }

    func testConversionIsItsOwnInverse() {
        let original = CGRect(x: -20, y: -1050, width: 300, height: 200)
        let there = cocoaFrame(fromWindowServer: original, displayHeight: 900)
        XCTAssertEqual(cocoaFrame(fromWindowServer: there, displayHeight: 900), original)
    }

    // MARK: Matching

    func testMatchesTheEntryWhoseBoundsEqualTheAXFrame() {
        let matches = matchServerWindows(
            axFrames: [id(1): frame],
            server: [ServerWindow(pid: 1, bounds: frame.offsetBy(dx: 1, dy: -1))]
        )
        XCTAssertEqual(matches[id(1)], .matched(frame.offsetBy(dx: 1, dy: -1)))
    }

    func testAStaleWindowWithTheSameSizeMatchesBySizeAndReportsItsRealBounds() {
        let stale = frame.offsetBy(dx: 900, dy: 0)
        let matches = matchServerWindows(axFrames: [id(1): frame], server: [ServerWindow(pid: 1, bounds: stale)])
        XCTAssertEqual(matches[id(1)], .matched(stale))
    }

    func testOtherPidsAreNeverCandidates() {
        let matches = matchServerWindows(axFrames: [id(1): frame], server: [ServerWindow(pid: 2, bounds: frame)])
        XCTAssertEqual(matches[id(1)], .missing)
    }

    func testADifferentSizeIsNotAMatch() {
        let other = CGRect(x: 100, y: 200, width: 300, height: 400)
        let matches = matchServerWindows(axFrames: [id(1): frame], server: [ServerWindow(pid: 1, bounds: other)])
        XCTAssertEqual(matches[id(1)], .missing)
    }

    func testSeveralSameSizeEntriesWithoutAnExactOneAreAmbiguous() {
        let matches = matchServerWindows(
            axFrames: [id(1): frame],
            server: [
                ServerWindow(pid: 1, bounds: frame.offsetBy(dx: 300, dy: 0)),
                ServerWindow(pid: 1, bounds: frame.offsetBy(dx: -300, dy: 0)),
            ]
        )
        XCTAssertEqual(matches[id(1)], .ambiguous)
    }

    func testAnExactEntryWinsOverOtherSameSizeEntries() {
        let matches = matchServerWindows(
            axFrames: [id(1): frame],
            server: [
                ServerWindow(pid: 1, bounds: frame.offsetBy(dx: 300, dy: 0)),
                ServerWindow(pid: 1, bounds: frame),
            ]
        )
        XCTAssertEqual(matches[id(1)], .matched(frame))
    }

    func testAnEntryClaimedExactlyByASiblingIsNotACandidateForTheStaleWindow() {
        let sibling = frame.offsetBy(dx: 700, dy: 0)
        let stale = frame.offsetBy(dx: 1400, dy: 0)
        let matches = matchServerWindows(
            axFrames: [id(1, 1): frame, id(1, 2): sibling],
            server: [ServerWindow(pid: 1, bounds: sibling), ServerWindow(pid: 1, bounds: stale)]
        )
        XCTAssertEqual(matches[id(1, 2)], .matched(sibling))
        XCTAssertEqual(matches[id(1, 1)], .matched(stale))
    }

    // MARK: Tolerant matching (SM-02c)

    func testALearnedMinimumSizeStillMatchesTheUniqueNearFrame() {
        // AX says 888 wide, the app drew 900 after min-size learning.
        let ax = CGRect(x: 100, y: 200, width: 888, height: 400)
        let drawn = CGRect(x: 100, y: 200, width: 900, height: 400)
        let matches = matchServerWindows(axFrames: [id(1): ax], server: [ServerWindow(pid: 1, bounds: drawn)])
        XCTAssertEqual(matches[id(1)], .matched(drawn))
    }

    func testSeveralNearFramesAreStillAmbiguous() {
        let ax = CGRect(x: 100, y: 200, width: 888, height: 400)
        let matches = matchServerWindows(
            axFrames: [id(1): ax],
            server: [
                ServerWindow(pid: 1, bounds: CGRect(x: 100, y: 200, width: 900, height: 400)),
                ServerWindow(pid: 1, bounds: CGRect(x: 102, y: 200, width: 910, height: 400)),
            ]
        )
        XCTAssertEqual(matches[id(1)], .ambiguous)
    }

    func testAFarSmallOrOtherPidFrameIsNotNear() {
        let ax = CGRect(x: 100, y: 200, width: 888, height: 400)
        let far = CGRect(x: 1500, y: 200, width: 900, height: 400)
        XCTAssertEqual(
            matchServerWindows(axFrames: [id(1): ax], server: [ServerWindow(pid: 1, bounds: far)])[id(1)], .missing
        )
    }

    func testALearnedMinimumSizeIsNotARenderMismatch() {
        let viewport = CGRect(x: 0, y: 0, width: 2000, height: 800)
        let ax = CGRect(x: 100, y: 200, width: 888, height: 400)
        let drawn = CGRect(x: 100, y: 200, width: 900, height: 400)
        let mismatches = findRenderMismatches(
            axFrames: [id(1): ax], server: [ServerWindow(pid: 1, bounds: drawn)],
            targets: [id(1): ax], viewports: [viewport]
        )
        XCTAssertEqual(mismatches, [])
    }

    // MARK: Missing windows (SM-02c)

    func testAVisibleTargetAbsentFromTheOnScreenListIsAMismatchWithNoServerFrame() {
        let viewport = CGRect(x: 0, y: 0, width: 2000, height: 800)
        let mismatches = findRenderMismatches(
            axFrames: [id(1): frame], server: [ServerWindow(pid: 2, bounds: frame)],
            targets: [id(1): frame], viewports: [viewport]
        )
        XCTAssertEqual(mismatches, [RenderMismatch(id: id(1), ax: frame, ws: nil)])
    }

    func testMissingWindowLogsWsMissing() {
        XCTAssertEqual(
            renderMismatchLine(id: id(7, 3), app: "WhatsApp", ax: frame, ws: nil),
            "render mismatch id=7:3 app=WhatsApp ax=(100,200,600,400) ws=missing"
        )
    }

    /// Two displays (2026-10-14): columns empty while AX reported the windows at their
    /// targets. The detail names every WindowServer entry of the app, on screen or not,
    /// and the display (1-based, by largest overlap) each one sits on.
    func testMissingDetailNamesEveryEntryOfTheAppAndItsDisplay() {
        let laptop = CGRect(x: 0, y: 0, width: 1800, height: 1130)
        let external = CGRect(x: -2160, y: -224, width: 2160, height: 1410)
        let line = renderMissingDetailLine(
            id: id(7, 3),
            entries: [
                ServerWindowState(bounds: CGRect(x: 904, y: 8, width: 888, height: 1114), isOnScreen: false),
                ServerWindowState(bounds: CGRect(x: -1500, y: 100, width: 888, height: 1114), isOnScreen: true),
                ServerWindowState(bounds: CGRect(x: 1900, y: -1300, width: 888, height: 1114), isOnScreen: true),
            ],
            displays: [laptop, external]
        )
        XCTAssertEqual(
            line,
            "render missing detail id=7:3 entries=3 [(904,8,888,1114) on=n display=1]"
                + " [(-1500,100,888,1114) on=Y display=2] [(1900,-1300,888,1114) on=Y display=none]"
        )
    }

    func testMissingDetailKeepsTheFirstSixEntries() {
        let entries = (0..<8).map {
            ServerWindowState(bounds: CGRect(x: $0 * 10, y: 0, width: 100, height: 100), isOnScreen: true)
        }
        let line = renderMissingDetailLine(id: id(7, 3), entries: entries, displays: [])
        XCTAssertTrue(line.hasPrefix("render missing detail id=7:3 entries=8 "))
        XCTAssertEqual(line.components(separatedBy: "[(").count - 1, 6)
        XCTAssertTrue(line.hasSuffix(" more=2"))
    }

    // MARK: Mismatch decision

    func testTwoPointsOfDriftIsNotAMismatch() {
        XCTAssertFalse(isRenderMismatch(reference: frame, server: frame.offsetBy(dx: 2, dy: -2)))
        XCTAssertFalse(isRenderMismatch(
            reference: frame, server: CGRect(x: 100, y: 200, width: 602, height: 398)
        ))
    }

    func testMoreThanTwoPointsInPositionOrSizeIsAMismatch() {
        XCTAssertTrue(isRenderMismatch(reference: frame, server: frame.offsetBy(dx: 3, dy: 0)))
        XCTAssertTrue(isRenderMismatch(reference: frame, server: frame.offsetBy(dx: 0, dy: 40)))
        XCTAssertTrue(isRenderMismatch(
            reference: frame, server: CGRect(x: 100, y: 200, width: 603, height: 400)
        ))
    }

    func testOnlyWindowsWhoseTargetIntersectsTheViewportAreChecked() {
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let inside = CGRect(x: 100, y: 100, width: 300, height: 300)
        let parked = CGRect(x: -299, y: 100, width: 300, height: 300).offsetBy(dx: -2000, dy: 0)
        let mismatches = findRenderMismatches(
            axFrames: [id(1): inside, id(2): parked],
            server: [
                ServerWindow(pid: 1, bounds: inside.offsetBy(dx: 500, dy: 0)),
                ServerWindow(pid: 2, bounds: parked.offsetBy(dx: 500, dy: 0)),
            ],
            targets: [id(1): inside, id(2): parked],
            viewports: [viewport]
        )
        XCTAssertEqual(mismatches, [RenderMismatch(id: id(1), ax: inside, ws: inside.offsetBy(dx: 500, dy: 0))])
    }

    func testAgreeingAndAmbiguousWindowsAreNotReported() {
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let a = CGRect(x: 0, y: 0, width: 300, height: 300)
        let b = CGRect(x: 400, y: 0, width: 300, height: 300)
        let mismatches = findRenderMismatches(
            axFrames: [id(1): a, id(2): b],
            server: [
                ServerWindow(pid: 1, bounds: a),
                ServerWindow(pid: 2, bounds: b.offsetBy(dx: 100, dy: 0)),
                ServerWindow(pid: 2, bounds: b.offsetBy(dx: -100, dy: 0)),
            ],
            targets: [id(1): a, id(2): b],
            viewports: [viewport]
        )
        XCTAssertEqual(mismatches, [])
    }

    // MARK: Nudge plan

    func testNudgeWritesAnOffsetFrameThenTheTarget() {
        let viewport = CGRect(x: 0, y: 0, width: 2000, height: 800)
        XCTAssertEqual(planNudge(target: frame, viewport: viewport), [frame.offsetBy(dx: 1, dy: 0), frame])
    }

    func testNudgeOffsetsInwardWhenTheTargetTouchesTheRightEdge() {
        let viewport = CGRect(x: 0, y: 0, width: 700, height: 800)
        XCTAssertEqual(planNudge(target: frame, viewport: viewport), [frame.offsetBy(dx: -1, dy: 0), frame])
    }

    /// PF-C: the second tier changes the size, so the app commits a new
    /// surface; it shrinks in place (never past the viewport) and restores.
    func testSizeNudgeShrinksOnePointThenRestoresTheTarget() {
        let viewport = CGRect(x: 0, y: 0, width: 2000, height: 800)
        XCTAssertEqual(
            planNudge(target: frame, viewport: viewport, tier: .size),
            [CGRect(x: frame.minX, y: frame.minY, width: frame.width - 1, height: frame.height), frame]
        )
    }

    // MARK: Single shot and cancellation

    func testAWindowIsNudgedOncePerSettle() {
        var book = RenderCheckBook()
        _ = book.schedule()
        XCTAssertEqual(book.claimNudges([id(1), id(2)]), [id(1), id(2)])
        XCTAssertEqual(book.claimNudges([id(1), id(3)]), [id(3)])
        _ = book.schedule()
        XCTAssertEqual(book.claimNudges([id(1)]), [id(1)])
    }

    func testANewMotionCancelsThePendingCheck() {
        var book = RenderCheckBook()
        let token = book.schedule()
        XCTAssertTrue(book.isCurrent(token))
        book.cancel()
        XCTAssertFalse(book.isCurrent(token))
    }

    func testSchedulingSupersedesTheEarlierCheck() {
        var book = RenderCheckBook()
        let first = book.schedule()
        let second = book.schedule()
        XCTAssertFalse(book.isCurrent(first))
        XCTAssertTrue(book.isCurrent(second))
    }

    func testMismatchWarnsOncePerWindowThenDebug() {
        var book = RenderCheckBook()
        XCTAssertEqual(book.mismatchLevel(for: id(1)), .warn)
        XCTAssertEqual(book.mismatchLevel(for: id(1)), .debug)
        XCTAssertEqual(book.mismatchLevel(for: id(2)), .warn)
    }

    // MARK: Log lines

    func testLogLinesCarryIdsAndAppNamesOnly() {
        XCTAssertEqual(
            renderMismatchLine(id: id(7, 3), app: "Code", ax: frame, ws: frame.offsetBy(dx: 900, dy: 0)),
            "render mismatch id=7:3 app=Code ax=(100,200,600,400) ws=(1000,200,600,400)"
        )
    }

    // MARK: Reconciler read and nudge

    private final class Recorder: WindowActuator, @unchecked Sendable {
        private let lock = NSLock()
        var frames: [WindowID: CGRect] = [:]
        private(set) var writes: [(WindowID, CGRect, CGRect, Bool)] = []
        private(set) var focuses = 0

        func frame(of id: WindowID) throws -> CGRect? { lock.withLock { frames[id] } }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {}
        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            lock.withLock { writes.append((id, frame, current, verify)) }
        }
        func focus(id: WindowID) throws { lock.withLock { focuses += 1 } }
    }

    func testReconcilerReadsFramesWithoutWriting() {
        let actuator = Recorder()
        actuator.frames = [id(1): frame]
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        XCTAssertEqual(reconciler.currentFrames(of: [id(1), id(2)]), [id(1): frame])
        XCTAssertTrue(actuator.writes.isEmpty)
    }

    func testReconcilerNudgeWritesEachStepFromThePreviousOne() {
        let actuator = Recorder()
        actuator.frames = [id(1): frame]
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        let steps = [frame.offsetBy(dx: 1, dy: 0), frame]
        let written = reconciler.nudge(steps: [id(1): steps])
        XCTAssertEqual(written, [id(1)])
        XCTAssertEqual(actuator.writes.map(\.1), steps)
        XCTAssertEqual(actuator.writes.map(\.2), [frame, frame.offsetBy(dx: 1, dy: 0)])
        XCTAssertEqual(actuator.writes.map(\.3), [false, false])
        XCTAssertEqual(actuator.focuses, 0)
    }

    func testReconcilerNudgeSkipsVanishedWindows() {
        let actuator = Recorder()
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        XCTAssertEqual(reconciler.nudge(steps: [id(1): [frame]]), [])
        XCTAssertTrue(actuator.writes.isEmpty)
    }
}
