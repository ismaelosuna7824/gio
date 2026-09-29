import XCTest
@testable import GioCore

/// PA-04: the ring is published only when what the overlay draws changed.
final class FocusRingGateTests: XCTestCase {
    private let color = ThemeColor(hex: "#7fc8ff")!

    private func shown(_ frame: CGRect, width: CGFloat = 4) -> FocusRingState {
        .shown(FocusRingGeometry(frame: frame, width: width, color: color))
    }

    private let base = CGRect(x: 100, y: 100, width: 600, height: 500)

    func testFirstStatePublishes() {
        var gate = FocusRingPublishGate()
        XCTAssertTrue(gate.shouldPublish(shown(base)))
    }

    func testFirstHiddenStatePublishesToo() {
        var gate = FocusRingPublishGate()
        XCTAssertTrue(gate.shouldPublish(.hidden))
    }

    func testIdenticalStateIsSkipped() {
        var gate = FocusRingPublishGate()
        _ = gate.shouldPublish(shown(base))
        XCTAssertFalse(gate.shouldPublish(shown(base)))
    }

    func testSubPointMovementIsSkipped() {
        var gate = FocusRingPublishGate()
        _ = gate.shouldPublish(shown(base))
        XCTAssertFalse(gate.shouldPublish(shown(base.offsetBy(dx: 0.6, dy: -0.4))))
    }

    func testOnePointMovementPublishes() {
        var gate = FocusRingPublishGate()
        _ = gate.shouldPublish(shown(base))
        XCTAssertTrue(gate.shouldPublish(shown(base.offsetBy(dx: 1, dy: 0))))
    }

    func testDriftIsMeasuredAgainstTheLastPublishedFrame() {
        var gate = FocusRingPublishGate()
        _ = gate.shouldPublish(shown(base))
        XCTAssertFalse(gate.shouldPublish(shown(base.offsetBy(dx: 0.6, dy: 0))))
        XCTAssertTrue(gate.shouldPublish(shown(base.offsetBy(dx: 1.2, dy: 0))))
    }

    func testSizeChangePublishes() {
        var gate = FocusRingPublishGate()
        _ = gate.shouldPublish(shown(base))
        XCTAssertTrue(gate.shouldPublish(shown(CGRect(x: 100, y: 100, width: 602, height: 500))))
    }

    func testVisibilityChangesPublish() {
        var gate = FocusRingPublishGate()
        _ = gate.shouldPublish(shown(base))
        XCTAssertTrue(gate.shouldPublish(.hidden))
        XCTAssertFalse(gate.shouldPublish(.hidden))
        XCTAssertTrue(gate.shouldPublish(shown(base)))
    }

    func testStyleChangePublishesEvenWithTheSameFrame() {
        var gate = FocusRingPublishGate()
        _ = gate.shouldPublish(shown(base))
        XCTAssertTrue(gate.shouldPublish(shown(base, width: 6)))
        let other = FocusRingState.shown(FocusRingGeometry(frame: base, width: 6, color: ThemeColor(hex: "#ff0000")!))
        XCTAssertTrue(gate.shouldPublish(other))
    }

    func testResetForcesTheNextPublication() {
        var gate = FocusRingPublishGate()
        _ = gate.shouldPublish(shown(base))
        gate.reset()
        XCTAssertTrue(gate.shouldPublish(shown(base)))
    }
}
