import CoreGraphics
import XCTest
@testable import GioCore

/// WC-19: the level bookkeeping behind "a floating window stays above the
/// strip".
final class FloatingLevelPlanTests: XCTestCase {
    private let a = WindowID(pid: 10, elementID: 1)
    private let b = WindowID(pid: 10, elementID: 2)
    private let c = WindowID(pid: 11, elementID: 3)

    func testANewFloatIsRaised() {
        XCTAssertEqual(
            floatingLevelChanges(raised: [], floating: [a]),
            FloatingLevelChanges(raise: [a])
        )
    }

    func testAWindowThatStoppedFloatingIsRestored() {
        XCTAssertEqual(
            floatingLevelChanges(raised: [a, b], floating: [a]),
            FloatingLevelChanges(restore: [b])
        )
    }

    func testNothingChangesWhenTheFloatsAreTheSame() {
        XCTAssertTrue(floatingLevelChanges(raised: [a, b], floating: [b, a]).isEmpty)
    }

    func testAFloatThatChangedOnlyItsFrameIsNotRaisedAgain() {
        // Idempotent: the level is per window, not per frame.
        XCTAssertTrue(floatingLevelChanges(raised: [a], floating: [a]).isEmpty)
    }

    func testManyAtOnce() {
        XCTAssertEqual(
            floatingLevelChanges(raised: [a], floating: [b, c]),
            FloatingLevelChanges(raise: [b, c], restore: [a])
        )
    }
}
