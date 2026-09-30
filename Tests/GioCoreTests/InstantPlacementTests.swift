import XCTest
@testable import GioCore

/// The first layout of a session (launch, `gio restart`, Accessibility
/// regained) is written instantly; later passes animate normally.
final class InstantPlacementTests: XCTestCase {
    func testTheFirstPassOfASessionIsInstantThenPassesAnimate() {
        var gate = InstantPlacementGate()
        XCTAssertEqual(gate.decide(requested: true), .instant(.startup))
        XCTAssertEqual(gate.decide(requested: true), .animate)
        XCTAssertEqual(gate.decide(requested: true), .animate)
    }

    func testAPassThatWasNotAskedToAnimateStaysInstantAndStillConsumesTheArm() {
        var gate = InstantPlacementGate()
        XCTAssertEqual(gate.decide(requested: false), .instant(.startup))
        XCTAssertEqual(gate.decide(requested: false), .instant(nil))
        XCTAssertEqual(gate.decide(requested: true), .animate)
    }

    func testArmingMakesTheNextPassInstantOnce() {
        var gate = InstantPlacementGate()
        _ = gate.decide(requested: true)
        gate.arm(.permission)
        XCTAssertEqual(gate.decide(requested: true), .instant(.permission))
        XCTAssertEqual(gate.decide(requested: true), .animate)
        gate.arm(.mouse)
        XCTAssertEqual(gate.decide(requested: true), .instant(.mouse))
    }

    func testTheFirstReasonArmedWins() {
        var gate = InstantPlacementGate()
        gate.arm(.mouse)
        XCTAssertEqual(gate.decide(requested: true), .instant(.startup))
    }

    func testReasonsHaveLogNames() {
        XCTAssertEqual(InstantPlacementReason.startup.rawValue, "startup")
        XCTAssertEqual(InstantPlacementReason.permission.rawValue, "permission")
        XCTAssertEqual(InstantPlacementReason.mouse.rawValue, "mouse")
        XCTAssertEqual(instantPlacementLogLine(.startup), "layout instant reason=startup")
    }
}
