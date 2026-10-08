import XCTest
@testable import GioCore

/// Live 2026-10-08: Enter in Chrome's address bar moved Gio's focus to a
/// neighbour column. Removing windows must never leave the focused column
/// pointing away from the focused window.
final class StripFocusTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 1, elementID: element)
    }

    private func workspace(focus: Int) -> Workspace {
        var workspace = Workspace(id: WorkspaceID(1), columns: (1...3).map {
            Column(id: ColumnID(UInt64($0)), width: 0, windows: [id(UInt64($0))], focusedWindowIndex: 0)
        })
        workspace.focusedColumn = focus
        workspace.focusedWindow = id(UInt64(focus + 1))
        return workspace
    }

    func testClosingAColumnLeftOfTheFocusKeepsTheFocusedColumnOnTheFocusedWindow() {
        var strip = workspace(focus: 1)
        strip.stripWindows([id(1)])
        XCTAssertEqual(strip.focusedWindow, id(2))
        XCTAssertEqual(strip.focusedColumn, 0)
        XCTAssertEqual(strip.columns[strip.focusedColumn].windows, [id(2)])
    }

    func testClosingTheFocusedColumnStillFallsBackToANeighbour() {
        var strip = workspace(focus: 2)
        strip.stripWindows([id(3)])
        XCTAssertEqual(strip.focusedColumn, 1)
        XCTAssertEqual(strip.focusedWindow, id(2))
    }
}
