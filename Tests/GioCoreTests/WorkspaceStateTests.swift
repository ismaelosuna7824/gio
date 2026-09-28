import XCTest
@testable import GioCore

final class WorkspaceStateTests: XCTestCase {
    private func column(
        id: UInt64 = 1,
        width: CGFloat = 800,
        windows: [WindowID] = [],
        focused: Int = 0
    ) -> Column {
        Column(
            id: ColumnID(id),
            width: width,
            windows: windows,
            focusedWindowIndex: focused
        )
    }

    func testEmptyWorkspaceDefaults() {
        let workspace = Workspace(id: WorkspaceID(1))
        XCTAssertTrue(workspace.columns.isEmpty)
        XCTAssertEqual(workspace.focusedColumn, 0)
        XCTAssertNil(workspace.focusedWindow)
        XCTAssertEqual(workspace.viewportOffset, 0)
        XCTAssertNil(workspace.focusedColumnRef)
    }

    func testFocusedColumnRef() {
        let first = column(id: 1)
        let second = column(id: 2)
        var workspace = Workspace(id: WorkspaceID(1), columns: [first, second], focusedColumn: 1)
        XCTAssertEqual(workspace.focusedColumnRef, second)
        workspace.focusedColumn = 7
        XCTAssertNil(workspace.focusedColumnRef)
    }

    func testColumnFocusedWindowID() {
        let a = WindowID(pid: 10, elementID: 1)
        let b = WindowID(pid: 10, elementID: 2)
        XCTAssertEqual(column(windows: [a, b], focused: 1).focusedWindowID, b)
        XCTAssertNil(column(windows: [a, b], focused: 5).focusedWindowID)
        XCTAssertNil(column().focusedWindowID)
    }

    func testStateIsValueType() {
        let original = Workspace(
            id: WorkspaceID(1),
            columns: [column(id: 1, windows: [WindowID(pid: 1, elementID: 1)])],
            focusedWindow: WindowID(pid: 1, elementID: 1),
            viewportOffset: 100
        )
        var copy = original
        copy.columns[0].windows = []
        copy.focusedWindow = nil
        copy.viewportOffset = 0
        XCTAssertEqual(original.columns[0].windows.count, 1)
        XCTAssertNotNil(original.focusedWindow)
        XCTAssertEqual(original.viewportOffset, 100)
    }

    func testViewportOffsetAndWidthsAreStored() {
        let workspace = Workspace(
            id: WorkspaceID(3),
            columns: [column(id: 1, width: 640), column(id: 2, width: 960)],
            viewportOffset: 1280
        )
        XCTAssertEqual(workspace.viewportOffset, 1280)
        XCTAssertEqual(workspace.columns.map(\.width), [640, 960])
    }
}
