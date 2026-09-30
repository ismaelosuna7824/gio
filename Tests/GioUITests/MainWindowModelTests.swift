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
}
