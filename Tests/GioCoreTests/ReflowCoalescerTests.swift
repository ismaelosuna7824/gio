import XCTest
@testable import GioCore

/// FI-06: while a motion is in flight, rapid actions update logical state at
/// once but at most one retarget reflow runs per motion tick.
final class ReflowCoalescerTests: XCTestCase {
    func testWithoutMotionEveryRequestRunsAtOnce() {
        var coalescer = ReflowCoalescer()
        XCTAssertEqual(coalescer.request(motionActive: false), .runNow)
        XCTAssertEqual(coalescer.request(motionActive: false), .runNow)
        XCTAssertFalse(coalescer.takeAtTick())
    }

    func testRequestsDuringMotionDeferAndMergeIntoOneTickReflow() {
        var coalescer = ReflowCoalescer()
        for _ in 0..<5 {
            XCTAssertEqual(coalescer.request(motionActive: true), .deferToTick)
        }
        XCTAssertTrue(coalescer.takeAtTick())
        XCTAssertFalse(coalescer.takeAtTick())
    }

    func testResetDropsAPendingRequest() {
        var coalescer = ReflowCoalescer()
        _ = coalescer.request(motionActive: true)
        coalescer.reset()
        XCTAssertFalse(coalescer.takeAtTick())
    }

    func testRunNowClearsAStalePendingRequest() {
        var coalescer = ReflowCoalescer()
        _ = coalescer.request(motionActive: true)
        XCTAssertEqual(coalescer.request(motionActive: false), .runNow)
        XCTAssertFalse(coalescer.takeAtTick())
    }
}
