import XCTest
@testable import GioCore

/// FX-01: a focus move whose window stays where it is (the other window of a
/// stacked column) shows the ring before the app's slow activation returns.
final class FocusRingLeadTests: XCTestCase {
    private let target = WindowID(pid: 10, elementID: 1)
    private let frame = CGRect(x: 8, y: 470, width: 900, height: 600)

    func testAWindowThatStaysPutLeadsItsFocus() {
        XCTAssertTrue(focusRingLeadsFocus(
            target: target, planned: [target: frame], parked: [], physical: frame
        ))
    }

    func testAWindowThatMovesWaitsForThePass() {
        XCTAssertFalse(focusRingLeadsFocus(
            target: target, planned: [target: frame.offsetBy(dx: -400, dy: 0)], parked: [], physical: frame
        ))
    }

    func testAParkedWindowWaits() {
        XCTAssertFalse(focusRingLeadsFocus(
            target: target, planned: [target: frame], parked: [target], physical: frame
        ))
    }

    func testAnUnknownFrameWaits() {
        XCTAssertFalse(focusRingLeadsFocus(target: target, planned: [target: frame], parked: [], physical: nil))
        XCTAssertFalse(focusRingLeadsFocus(target: target, planned: [:], parked: [], physical: frame))
    }

    func testNoFocusMoveLeadsNothing() {
        XCTAssertFalse(focusRingLeadsFocus(target: nil, planned: [target: frame], parked: [], physical: frame))
    }

    func testSubPointDifferenceStillCountsAsInPlace() {
        XCTAssertTrue(focusRingLeadsFocus(
            target: target, planned: [target: frame.offsetBy(dx: 0.4, dy: -0.3)], parked: [], physical: frame
        ))
    }
}
