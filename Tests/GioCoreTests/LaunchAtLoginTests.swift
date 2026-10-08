import XCTest
@testable import GioCore

/// DA-06: a login launch starts quietly in the menu bar.
final class LaunchAtLoginTests: XCTestCase {
    func testALoginLaunchStaysInTheMenuBar() {
        XCTAssertFalse(opensMainWindowAtLaunch(launchedAtLogin: true, accessibilityGranted: true))
    }

    func testAnOrdinaryLaunchOpensTheWindow() {
        XCTAssertTrue(opensMainWindowAtLaunch(launchedAtLogin: false, accessibilityGranted: true))
        XCTAssertTrue(opensMainWindowAtLaunch(launchedAtLogin: false, accessibilityGranted: false))
    }

    /// Without Accessibility nothing tiles; a silent login launch would hide why.
    func testALoginLaunchWithoutAccessibilityOpensTheWindow() {
        XCTAssertTrue(opensMainWindowAtLaunch(launchedAtLogin: true, accessibilityGranted: false))
    }
}
