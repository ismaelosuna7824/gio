import XCTest
@testable import GioUI

/// The setup cover sits above the menu bar while Gio is active, but a
/// permission request must drop it: macOS shows its permission alert while
/// Gio stays the active app, and the raised cover hid it.
final class SetupCoverStackingTests: XCTestCase {
    func testPresentedWhileActiveIsRaised() {
        XCTAssertTrue(SetupCoverStacking(appIsActive: true).isRaised)
        XCTAssertFalse(SetupCoverStacking(appIsActive: false).isRaised)
    }

    func testPermissionRequestLowersEvenWhileGioStaysActive() {
        var stacking = SetupCoverStacking(appIsActive: true)
        stacking.permissionRequested()
        XCTAssertFalse(stacking.isRaised)
    }

    func testReturningToGioRaisesAgainAfterARequest() {
        var stacking = SetupCoverStacking(appIsActive: true)
        stacking.permissionRequested()
        stacking.appResignedActive()
        XCTAssertFalse(stacking.isRaised)
        stacking.appBecameActive()
        XCTAssertTrue(stacking.isRaised)
    }

    func testResigningLowersAndActivatingRaises() {
        var stacking = SetupCoverStacking(appIsActive: true)
        stacking.appResignedActive()
        XCTAssertFalse(stacking.isRaised)
        stacking.appBecameActive()
        XCTAssertTrue(stacking.isRaised)
    }
}
