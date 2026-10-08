import XCTest
@testable import GioCore

/// HD-06: focusing a specific managed window (launcher / window id).
final class FocusWindowPlanTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func manager() -> WorkspaceManager {
        var manager = WorkspaceManager()
        var first = manager.currentWorkspace()
        first.columns = [Column(id: ColumnID(1), width: 0, windows: [id(1)])]
        first.focusedColumn = 0
        first.focusedWindow = id(1)
        manager.update(first)
        manager.focusDown()
        var second = manager.currentWorkspace()
        second.columns = [
            Column(id: ColumnID(1), width: 0, windows: [id(2)]),
            Column(id: ColumnID(2), width: 0, windows: [id(3), id(4)]),
        ]
        second.focusedColumn = 0
        second.focusedWindow = id(2)
        manager.update(second)
        manager.switchTo(1)
        return manager
    }

    func testWindowOnAnotherWorkspaceSwitchesToItAndFocusesIt() throws {
        let plan = try XCTUnwrap(planFocusWindow(id(4), in: manager()))
        XCTAssertEqual(plan.index, 2)
        XCTAssertTrue(plan.switchesWorkspace)
        XCTAssertEqual(plan.workspace.focusedWindow, id(4))
        XCTAssertEqual(plan.workspace.focusedColumn, 1)
        XCTAssertEqual(plan.workspace.columns[1].focusedWindowIndex, 1)
    }

    func testWindowOnTheCurrentWorkspaceDoesNotSwitch() throws {
        let plan = try XCTUnwrap(planFocusWindow(id(1), in: manager()))
        XCTAssertEqual(plan.index, 1)
        XCTAssertFalse(plan.switchesWorkspace)
    }

    func testRevealingAHiddenWorkspaceIsAWorkspaceSwitch() throws {
        let plan = try XCTUnwrap(planFocusWindow(id(4), in: manager()))
        XCTAssertEqual(plan.revealCause, .workspaceSwitch)
    }

    func testFocusingAnotherDisplaysShownWorkspaceSwitchesNothing() throws {
        // MM-01: only the focused display changes; no workspace slides.
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(1), DisplayID(2))
        manager.syncDisplays([a, b], main: a)
        var shownOnB = manager.workspace(id: manager.activeID(on: b)!)!
        shownOnB.columns = [Column(id: ColumnID(1), width: 0, windows: [id(7)])]
        manager.update(shownOnB)
        let plan = try XCTUnwrap(planFocusWindow(id(7), in: manager))
        XCTAssertTrue(plan.switchesWorkspace, "the session's current workspace changes")
        XCTAssertEqual(plan.revealCause, .passive)
    }

    func testUnknownWindowHasNoPlan() {
        XCTAssertNil(planFocusWindow(id(99), in: manager()))
    }

    func testWindowIDParsesItsStatusText() {
        XCTAssertEqual(WindowID(text: "123:45"), WindowID(pid: 123, elementID: 45))
        for bad in ["", "12", "a:b", "1:2:3", "-1:2", "1:-2", " 1:2"] {
            XCTAssertNil(WindowID(text: bad), bad)
        }
    }
}
