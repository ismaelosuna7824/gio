import XCTest
@testable import GioUI

/// Pure pieces of the unified main window: sidebar sections and the
/// activation-policy rule. The NSWindow / SwiftUI shell is live-only.
final class MainWindowModelTests: XCTestCase {
    func testSectionsAreInSidebarOrder() {
        XCTAssertEqual(
            MainSection.allCases.map(\.title),
            ["Overview", "Shortcuts", "Layout", "Animations", "Rules", "Logs"]
        )
    }

    func testEverySectionHasSymbolAndUniqueId() {
        XCTAssertEqual(Set(MainSection.allCases.map(\.id)).count, MainSection.allCases.count)
        for section in MainSection.allCases {
            XCTAssertFalse(section.symbol.isEmpty, "\(section) has no symbol")
        }
    }

    func testImplementedFlagMatchesPlaceholders() {
        XCTAssertTrue(MainSection.overview.isImplemented)
        XCTAssertTrue(MainSection.shortcuts.isImplemented)
        XCTAssertFalse(MainSection.layout.isImplemented)
    }

    func testPolicyIsRegularOnlyWhileWindowVisible() {
        XCTAssertEqual(desiredActivationPolicy(windowVisible: true), .regular)
        XCTAssertEqual(desiredActivationPolicy(windowVisible: false), .accessory)
    }
}
