import XCTest
@testable import GioCore

final class WorkspacePreferencesTests: XCTestCase {
    func testNamesPersistAndInvalidNamesDoNotOverwrite() {
        let suite = "gio-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let names = WorkspacePreferences(defaults: defaults)
        XCTAssertEqual(names.name(for: 2), "Workspace 2")
        XCTAssertTrue(names.rename(2, to: "  Focus  "))
        XCTAssertEqual(WorkspacePreferences(defaults: defaults).name(for: 2), "Focus")
        XCTAssertFalse(names.rename(2, to: "  "))
        XCTAssertFalse(names.rename(5, to: "Other"))
        XCTAssertFalse(names.rename(2, to: String(repeating: "x", count: 41)))
        XCTAssertEqual(names.name(for: 2), "Focus")
    }
}
