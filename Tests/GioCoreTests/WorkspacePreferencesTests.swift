import XCTest
@testable import GioCore

final class WorkspacePreferencesTests: XCTestCase {
    func testTilingDefaultsOffPerDisplayAndGapsRejectInvalidValues() {
        let suite = "gio-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WorkspacePreferences(defaults: defaults)
        XCTAssertFalse(settings.tilingEnabled(on: "1"))
        settings.setTilingEnabled(true, on: "1")
        XCTAssertTrue(WorkspacePreferences(defaults: defaults).tilingEnabled(on: "1"))
        XCTAssertFalse(settings.tilingEnabled(on: "2"))
        XCTAssertEqual(settings.gap, 0)
        XCTAssertTrue(settings.setGap(8))
        XCTAssertFalse(settings.setGap(-1))
        XCTAssertFalse(settings.setGap(999))
        XCTAssertEqual(WorkspacePreferences(defaults: defaults).gap, 8)
        settings.setTilingEnabled(false, on: "1")
        XCTAssertFalse(settings.tilingEnabled(on: "1"))
    }

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
