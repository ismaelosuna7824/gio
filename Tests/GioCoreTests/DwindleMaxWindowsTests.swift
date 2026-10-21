import XCTest
@testable import GioCore

/// FX-04: `[dwindle] max-windows` (default 6). A workspace with more
/// windows does not become dwindle, and a dwindle workspace that gets one
/// window too many goes back to the strip, which holds any number.
final class DwindleMaxWindowsTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func manager(windows count: UInt64, max: Int = 6) -> WorkspaceManager {
        var manager = WorkspaceManager()
        manager.applyLayoutDefaults(WorkspaceLayoutDefaults(kind: .scrolling, splitRatio: 1, maxWindows: max))
        var workspace = manager.currentWorkspace()
        workspace.columns = (1...count).map { Column(id: ColumnID($0), width: 0, windows: [id($0)]) }
        workspace.focusedColumn = 0
        workspace.focusedWindow = id(1)
        manager.update(workspace)
        return manager
    }

    private func add(_ n: UInt64, to manager: inout WorkspaceManager) {
        var workspace = manager.currentWorkspace()
        workspace.columns.append(Column(id: ColumnID(n), width: 0, windows: [id(n)]))
        manager.update(workspace)
    }

    func testTheDefaultIsSix() {
        XCTAssertEqual(WorkspaceLayoutDefaults().maxWindows, 6)
        XCTAssertEqual(GioConfig().dwindle.maxWindows, 6)
        XCTAssertEqual(GioConfig().layoutDefaults.maxWindows, 6)
    }

    func testAWorkspaceOverTheMaximumStaysScrolling() {
        var manager = manager(windows: 7)
        let before = manager.currentWorkspace()
        XCTAssertFalse(manager.toggleLayout())
        XCTAssertFalse(manager.setLayout(.dwindle))
        XCTAssertEqual(manager.currentWorkspace(), before, "refused: nothing changes")
        XCTAssertEqual(manager.dwindleRefusal(), DwindleRefusal(windows: 7, maximum: 6))
    }

    func testAWorkspaceAtTheMaximumBecomesDwindle() {
        var manager = manager(windows: 6)
        XCTAssertNil(manager.dwindleRefusal())
        XCTAssertTrue(manager.toggleLayout())
        XCTAssertEqual(manager.currentWorkspace().layout, .dwindle)
    }

    func testOneWindowTooManyReturnsTheWorkspaceToTheStrip() {
        var manager = manager(windows: 6)
        XCTAssertTrue(manager.setLayout(.dwindle))
        add(7, to: &manager)
        let workspace = manager.currentWorkspace()
        XCTAssertEqual(workspace.layout, .scrolling)
        XCTAssertEqual(Set(workspace.windows), Set((1...7).map(id)), "every window stays")
        XCTAssertEqual(workspace.dwindle, DwindleState())
    }

    func testLoweringTheMaximumReturnsAFullDwindleWorkspaceToTheStrip() {
        var manager = manager(windows: 5)
        XCTAssertTrue(manager.setLayout(.dwindle))
        manager.applyLayoutDefaults(WorkspaceLayoutDefaults(kind: .scrolling, splitRatio: 1, maxWindows: 4))
        XCTAssertEqual(manager.currentWorkspace().layout, .scrolling)
        XCTAssertEqual(manager.currentWorkspace().windows.count, 5)
    }

    func testTheKeyParsesAndBadValuesKeepTheDefault() throws {
        let (config, warnings) = try parseGioConfig("[dwindle]\nmax-windows = 4\n").get()
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.dwindle.maxWindows, 4)
        XCTAssertEqual(config.layoutDefaults.maxWindows, 4)
        for bad in ["0", "33", "2.5", "\"many\""] {
            let (kept, badWarnings) = try parseGioConfig("[dwindle]\nmax-windows = \(bad)\n").get()
            XCTAssertEqual(kept.dwindle.maxWindows, 6, bad)
            XCTAssertEqual(badWarnings, ["line 2: dwindle.max-windows expects a whole number from 1 to 32, default kept"], bad)
        }
    }

    func testTheSettingsFormEditsTheKey() {
        var config = GioConfig()
        config.dwindle.maxWindows = 4
        var form = LayoutSettingsForm(config: config.layout, dwindle: config.dwindle)
        XCTAssertEqual(form.maxWindows, 4)
        XCTAssertTrue(form.edits.contains(.set(table: "dwindle", key: "max-windows", value: .int(4))))
        form.maxWindows = 0
        XCTAssertEqual(form.problems, ["Dwindle maximum windows must be 1 to 32."])
    }
}
