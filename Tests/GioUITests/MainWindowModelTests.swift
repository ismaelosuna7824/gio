import XCTest
@testable import GioUI

/// Pure pieces of the unified main window: sidebar sections and the
/// activation-policy rule. The NSWindow / SwiftUI shell is live-only.
final class MainWindowModelTests: XCTestCase {
    func testSectionsAreInSidebarOrder() {
        XCTAssertEqual(
            MainSection.allCases.map(\.title),
            ["Overview", "Shortcuts", "Workspaces", "Layout", "Focus", "Animations", "Rules", "Logs", "Diagnostics"]
        )
    }

    func testEverySectionHasSymbolAndUniqueId() {
        XCTAssertEqual(Set(MainSection.allCases.map(\.id)).count, MainSection.allCases.count)
        for section in MainSection.allCases {
            XCTAssertFalse(section.symbol.isEmpty, "\(section) has no symbol")
        }
    }

    func testPolicyIsRegularOnlyWhileWindowVisible() {
        XCTAssertEqual(desiredActivationPolicy(windowVisible: true), .regular)
        XCTAssertEqual(desiredActivationPolicy(windowVisible: false), .accessory)
    }

    /// DA-16 (user choice 2026-11-04): another app taking focus hides the
    /// open window instead of leaving it cut off behind that app.
    func testWindowHidesWhenAnotherAppIsActivated() {
        XCTAssertTrue(mainWindowHidesOnActivation(
            windowVisible: true, setupShowing: false, activatedPID: 42, activatedBundleID: "com.apple.Terminal", ownPID: 1
        ))
    }

    /// Gio itself, the setup (its steps send you to System Settings) and a
    /// trip to System Settings (permissions, login items) keep it open.
    func testWindowStaysForGioTheSetupAndSystemSettings() {
        XCTAssertFalse(mainWindowHidesOnActivation(
            windowVisible: true, setupShowing: false, activatedPID: 1, activatedBundleID: "dev.gio.windowmanager", ownPID: 1
        ))
        XCTAssertFalse(mainWindowHidesOnActivation(
            windowVisible: true, setupShowing: true, activatedPID: 42, activatedBundleID: "com.apple.Terminal", ownPID: 1
        ))
        XCTAssertFalse(mainWindowHidesOnActivation(
            windowVisible: true, setupShowing: false, activatedPID: 42, activatedBundleID: "com.apple.systempreferences",
            ownPID: 1
        ))
        XCTAssertFalse(mainWindowHidesOnActivation(
            windowVisible: false, setupShowing: false, activatedPID: 42, activatedBundleID: "com.apple.Terminal", ownPID: 1
        ))
    }
}
