import CoreGraphics
import XCTest
@testable import GioCore

/// SM-04: renderer choice per motion (snapshot vs AX fallback), retarget
/// merge, completion gate and log lines. Pure.
final class SnapshotFlightPlanningTests: XCTestCase {
    private func id(_ n: UInt64) -> WindowID { WindowID(pid: 10, elementID: n) }
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let other = CGRect(x: 1000, y: 0, width: 1000, height: 800)
    private func win(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: 400, height: 800) }
    private let all: (WindowID) -> Bool = { _ in true }

    // MARK: plan selection

    func testEveryVisibleWindowWithAnImageMakesASnapshotFlight() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(-300), id(2): win(100)],
            displays: [display], hasImage: all, backdropReady: { _ in true }
        )
        guard case .snapshot(let items) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1), id(2)])
        XCTAssertEqual(items[1].from, win(400))
        XCTAssertEqual(items[1].to, win(100))
        XCTAssertEqual(items.map(\.displayIndex), [0, 0])
    }

    func testAStaticVisibleWindowIsStillDrawnBecauseTheOverlayCoversIt() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(0), id(2): win(500)],
            displays: [display], hasImage: all, backdropReady: { _ in true }
        )
        guard case .snapshot(let items) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1), id(2)])
    }

    func testAMissingImageOfAnyVisibleWindowFallsBackToAXForTheWholeMotion() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(-300), id(2): win(100)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }
        )
        XCTAssertEqual(decision, .fallback(reason: .cacheMiss, missing: [id(2)]))
    }

    func testAWindowParkedBeforeAndAfterNeedsNoImage() {
        let parkedA = CGRect(x: -3000, y: 0, width: 400, height: 800)
        let parkedB = CGRect(x: -3100, y: 0, width: 400, height: 800)
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(9): parkedA], targets: [id(1): win(50), id(9): parkedB],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }
        )
        guard case .snapshot(let items) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1)])
    }

    func testAWindowScrollingInFromParkedNeedsAnImage() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(9): CGRect(x: -3000, y: 0, width: 400, height: 800)],
            targets: [id(1): win(-300), id(9): win(500)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }
        )
        XCTAssertEqual(decision, .fallback(reason: .cacheMiss, missing: [id(9)]))
    }

    func testOnlyDisplaysWithMovingWindowsGetLayers() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(1000)], targets: [id(1): win(50), id(2): win(1000)],
            displays: [display, other], hasImage: { $0 == id(1) }, backdropReady: { _ in true }
        )
        guard case .snapshot(let items) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1)])
    }

    func testNothingMovingOnScreenIsNotASnapshotFlight() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0)], targets: [id(1): win(0)],
            displays: [display], hasImage: all, backdropReady: { _ in true }
        )
        XCTAssertEqual(decision, .fallback(reason: .nothingVisible, missing: []))
    }

    func testAMissingBackdropFallsBack() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0)], targets: [id(1): win(50)],
            displays: [display], hasImage: all, backdropReady: { _ in false }
        )
        XCTAssertEqual(decision, .fallback(reason: .noBackdrop, missing: []))
    }

    func testARealWindowGetsExactlyOneWriteToItsFinalFrame() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(-300), id(2): win(100)],
            displays: [display], hasImage: all, backdropReady: { _ in true }
        )
        XCTAssertEqual(decision.finalFrames, [id(1): win(-300), id(2): win(100)])
    }

    // MARK: retarget merge

    func testRetargetKeepsLayersAddsNewOnesAndReportsUncovered() {
        let plan = planSnapshotRetarget(
            active: [id(1), id(2)],
            starts: [id(1): win(-300), id(2): win(100), id(3): win(2000), id(4): win(2500)],
            targets: [id(1): win(-700), id(2): win(-300), id(3): win(100), id(4): win(500)],
            displays: [display], activeDisplays: [0], hasImage: { $0 != id(4) }
        )
        XCTAssertEqual(plan.retargets, [id(1): win(-700), id(2): win(-300)])
        XCTAssertEqual(plan.adds.map(\.id), [id(3)])
        XCTAssertEqual(plan.adds.first?.from, win(2000))
        XCTAssertEqual(plan.uncovered, [id(4)])
    }

    func testRetargetIgnoresWindowsThatStayOffScreen() {
        let plan = planSnapshotRetarget(
            active: [id(1)], starts: [id(1): win(0), id(9): win(-3000)],
            targets: [id(1): win(50), id(9): win(-3100)],
            displays: [display], activeDisplays: [0], hasImage: { $0 == id(1) }
        )
        XCTAssertEqual(plan.adds, [])
        XCTAssertEqual(plan.uncovered, [])
    }

    // MARK: gate

    func testTheFlightSettlesOnlyWhenLayersAndTheFinalPassAreBothDone() {
        var gate = SnapshotFlightGate()
        let token = gate.begin()
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.layersFinished(token))
        XCTAssertTrue(gate.passSettled(token))
    }

    func testSettleFiresOnceAndAStaleTokenIsIgnored() {
        var gate = SnapshotFlightGate()
        let first = gate.begin()
        let second = gate.retarget()
        XCTAssertFalse(gate.layersFinished(first))
        XCTAssertFalse(gate.passSettled(first))
        XCTAssertFalse(gate.passSettled(second))
        XCTAssertTrue(gate.layersFinished(second))
        XCTAssertFalse(gate.layersFinished(second))
        XCTAssertFalse(gate.isActive)
    }

    func testAbortMakesEveryTokenStale() {
        var gate = SnapshotFlightGate()
        let token = gate.begin()
        gate.abort()
        XCTAssertFalse(gate.isActive)
        XCTAssertFalse(gate.layersFinished(token))
        XCTAssertFalse(gate.passSettled(token))
    }

    // MARK: log lines

    func testLogLines() {
        XCTAssertEqual(
            snapshotFlightLine(layers: 3, cacheAgeMilliseconds: 2500, duration: 0.356),
            "snapshot flight layers=3 cacheAgeMs=2500 duration=356ms"
        )
        XCTAssertEqual(snapshotFallbackLine(reason: .cacheMiss, count: 2), "snapshot fallback reason=cache-miss ids=2")
        XCTAssertEqual(snapshotFallbackLine(reason: .noBackdrop, count: 0), "snapshot fallback reason=no-backdrop ids=0")
    }

    func testAbortLinesNameTheReason() {
        XCTAssertEqual(snapshotAbortLine(reason: .watchdog), "snapshot flight aborted reason=watchdog")
        XCTAssertEqual(snapshotAbortLine(reason: .mouseDown), "snapshot flight aborted reason=mouse-down")
        XCTAssertEqual(snapshotAbortLine(reason: .displayChange), "snapshot flight aborted reason=display-change")
    }

    func testOnlyTheWatchdogIsAWarning() {
        XCTAssertEqual(SnapshotAbortReason.watchdog.logLevel, .warn)
        XCTAssertEqual(SnapshotAbortReason.mouseDown.logLevel, .info)
        XCTAssertEqual(SnapshotAbortReason.displayChange.logLevel, .info)
    }

    func testAnimDoneLineNamesTheRenderer() {
        let ax = MotionSummary(windows: 1, frames: 2, dropped: 0, duration: 0.2, slowest: nil)
        XCTAssertTrue(ax.logLine.hasSuffix("renderer=ax"))
        let snap = MotionSummary(windows: 1, frames: 0, dropped: 0, duration: 0.2, slowest: nil, curve: "spring", renderer: "snapshot")
        XCTAssertTrue(snap.logLine.hasSuffix("curve=spring sizeAnimated=0 renderer=snapshot"))
    }
}
