import XCTest
@testable import GioCore

final class SpaceGateTests: XCTestCase {
    func testStartsOnTheManagedSpaceAndAllowsWindowWork() {
        let gate = SpaceGate()

        XCTAssertTrue(gate.isManagedActive)
        XCTAssertTrue(gate.allowsWindowWork)
    }

    func testLeavingTheManagedSpaceBlocksWindowWork() {
        var gate = SpaceGate()

        let transition = gate.update(managedActive: false)

        XCTAssertEqual(transition, .left)
        XCTAssertFalse(gate.isManagedActive)
        XCTAssertFalse(gate.allowsWindowWork)
    }

    func testReturningToTheManagedSpaceAllowsWorkAndAsksForOneReflow() {
        var gate = SpaceGate()
        _ = gate.update(managedActive: false)

        let transition = gate.update(managedActive: true)

        XCTAssertEqual(transition, .returned)
        XCTAssertTrue(gate.allowsWindowWork)
    }

    func testRepeatedReportsOfTheSameStateAreUnchanged() {
        var gate = SpaceGate()

        XCTAssertEqual(gate.update(managedActive: true), .unchanged)
        _ = gate.update(managedActive: false)
        XCTAssertEqual(gate.update(managedActive: false), .unchanged)
        XCTAssertFalse(gate.allowsWindowWork)
    }

    func testAwayAndBackTwiceYieldsOneReturnPerVisit() {
        var gate = SpaceGate()
        var transitions: [SpaceGate.Transition] = []

        for active in [false, true, false, true] {
            transitions.append(gate.update(managedActive: active))
        }

        XCTAssertEqual(transitions, [.left, .returned, .left, .returned])
    }
}
