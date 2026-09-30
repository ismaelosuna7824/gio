import CoreGraphics
import XCTest
@testable import GioCore

/// Diagnostics: how long the WindowServer takes to draw a requested size.
final class ResizeLatencyProbeTests: XCTestCase {
    private let requested = CGSize(width: 1000, height: 700)

    func testPendingUntilTheObservedSizeMatches() {
        XCTAssertEqual(
            resizeProbeDecision(requested: requested, observed: CGSize(width: 600, height: 700), elapsed: 0.05),
            .pending
        )
        XCTAssertEqual(resizeProbeDecision(requested: requested, observed: nil, elapsed: 0.05), .pending)
    }

    func testReachedWithinTheToleranceReportsMilliseconds() {
        XCTAssertEqual(
            resizeProbeDecision(requested: requested, observed: CGSize(width: 1002, height: 698), elapsed: 0.1234),
            .reached(milliseconds: 123)
        )
    }

    func testOutsideTheToleranceIsNotAMatch() {
        XCTAssertEqual(
            resizeProbeDecision(requested: requested, observed: CGSize(width: 1002.5, height: 700), elapsed: 0.1),
            .pending
        )
    }

    func testTimesOutAfterTheLimit() {
        XCTAssertEqual(
            resizeProbeDecision(requested: requested, observed: CGSize(width: 10, height: 10), elapsed: 1.5),
            .timeout
        )
    }

    func testAMatchAtTheDeadlineStillCounts() {
        XCTAssertEqual(
            resizeProbeDecision(requested: requested, observed: requested, elapsed: 1.5),
            .reached(milliseconds: 1500)
        )
    }

    func testFirstTimeASizeIsSeenPerWindow() {
        var history = ResizeSizeHistory()
        let a = WindowID(pid: 1, elementID: 1)
        let b = WindowID(pid: 1, elementID: 2)
        XCTAssertTrue(history.recordIsFirst(a, size: requested))
        XCTAssertFalse(history.recordIsFirst(a, size: requested))
        XCTAssertTrue(history.recordIsFirst(b, size: requested))
        XCTAssertTrue(history.recordIsFirst(a, size: CGSize(width: 800, height: 700)))
    }

    func testHistoryIsBounded() {
        var history = ResizeSizeHistory(maxSizesPerWindow: 2, maxWindows: 2)
        let a = WindowID(pid: 1, elementID: 1)
        for width in [100, 200, 300] {
            XCTAssertTrue(history.recordIsFirst(a, size: CGSize(width: CGFloat(width), height: 50)))
        }
        XCTAssertTrue(history.recordIsFirst(a, size: CGSize(width: 100, height: 50)), "oldest size was evicted")
        for element in 2...5 {
            _ = history.recordIsFirst(WindowID(pid: 1, elementID: UInt64(element)), size: requested)
        }
        XCTAssertLessThanOrEqual(history.windowCount, 2)
    }

    func testLogLineFormat() {
        XCTAssertEqual(
            resizeLatencyLine(
                id: WindowID(pid: 42, elementID: 7), app: "Code", size: requested,
                result: .reached(milliseconds: 180), first: true
            ),
            "resize latency id=42:7 app=Code requestedSize=1000x700 wsMs=180 first=true"
        )
        XCTAssertEqual(
            resizeLatencyLine(
                id: WindowID(pid: 42, elementID: 7), app: "Code", size: requested, result: .timeout, first: false
            ),
            "resize latency id=42:7 app=Code requestedSize=1000x700 wsMs=timeout first=false"
        )
    }
}

/// Resize latency probe: skip windows that cannot be resized, and never log a
/// request that is already the current size.
final class ResizeProbeGateTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 5, elementID: element)
    }

    private let requested = CGSize(width: 1200, height: 800)

    func testProbesAGrowingResizableWindow() {
        let gate = ResizeProbeGate()
        XCTAssertTrue(gate.shouldStart(id(1), current: CGSize(width: 800, height: 800), requested: requested, sizeSettable: true))
        XCTAssertTrue(gate.shouldStart(id(1), current: nil, requested: requested, sizeSettable: true))
    }

    func testSkipsWindowsWhoseSizeIsNotSettable() {
        let gate = ResizeProbeGate()
        XCTAssertFalse(gate.shouldStart(id(1), current: CGSize(width: 800, height: 800), requested: requested, sizeSettable: false))
    }

    func testSkipsWhenTheRequestedSizeIsTheCurrentSize() {
        let gate = ResizeProbeGate()
        XCTAssertFalse(gate.shouldStart(id(1), current: CGSize(width: 1201.5, height: 799), requested: requested, sizeSettable: true))
        XCTAssertTrue(gate.shouldStart(id(1), current: CGSize(width: 1210, height: 800), requested: requested, sizeSettable: true))
    }

    func testATimeoutThatNeverMovedTheWindowMarksItFixedAndStopsProbing() {
        var gate = ResizeProbeGate()
        let started = CGSize(width: 800, height: 800)
        XCTAssertTrue(gate.recordTimeout(id(1), started: started, observed: CGSize(width: 800.5, height: 800)))
        XCTAssertFalse(gate.shouldStart(id(1), current: started, requested: requested, sizeSettable: true))
        XCTAssertTrue(gate.shouldStart(id(2), current: started, requested: requested, sizeSettable: true))
    }

    func testATimeoutAfterTheWindowMovedIsARealLatencyAndKeepsProbing() {
        var gate = ResizeProbeGate()
        XCTAssertFalse(gate.recordTimeout(
            id(1), started: CGSize(width: 800, height: 800), observed: CGSize(width: 1000, height: 800)
        ))
        XCTAssertTrue(gate.shouldStart(id(1), current: CGSize(width: 800, height: 800), requested: requested, sizeSettable: true))
        XCTAssertFalse(gate.recordTimeout(id(1), started: nil, observed: nil))
    }

    func testForgetLiftsAFixedMark() {
        var gate = ResizeProbeGate()
        _ = gate.recordTimeout(id(1), started: CGSize(width: 800, height: 800), observed: CGSize(width: 800, height: 800))
        gate.forget(id(1))
        XCTAssertTrue(gate.shouldStart(id(1), current: CGSize(width: 800, height: 800), requested: requested, sizeSettable: true))
    }
}
