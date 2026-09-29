import XCTest
@testable import GioCore

/// NC-04: center-column sets the viewport offset, clamped to content.
final class CenterColumnTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private let engine = ScrollableLayoutEngine(config: LayoutConfig(defaultColumnWidth: 880))

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    /// Five 880-wide columns: content = 8 + 5*880 + 4*8 + 8 = 4448.
    private func workspace(focusedColumn: Int, offset: CGFloat = 0) -> Workspace {
        let columns = (1...5).map {
            Column(id: ColumnID(UInt64($0)), width: 0, windows: [id(UInt64($0))])
        }
        return Workspace(
            id: WorkspaceID(1), columns: columns, focusedColumn: focusedColumn,
            focusedWindow: id(UInt64(focusedColumn + 1)), viewportOffset: offset
        )
    }

    func testCentersMiddleColumn() {
        let centered = centerFocusedColumn(
            in: workspace(focusedColumn: 2), modes: [:], engine: engine, viewport: viewport
        )
        // Column 2 spans 1784...2664 in content space; its center is 2224.
        XCTAssertEqual(centered.viewportOffset, 2224 - 900, accuracy: 0.001)
    }

    func testClampsAtBothEnds() {
        let first = centerFocusedColumn(
            in: workspace(focusedColumn: 0, offset: 500), modes: [:], engine: engine, viewport: viewport
        )
        XCTAssertEqual(first.viewportOffset, 0)
        let last = centerFocusedColumn(
            in: workspace(focusedColumn: 4), modes: [:], engine: engine, viewport: viewport
        )
        XCTAssertEqual(last.viewportOffset, 4448 - 1800, accuracy: 0.001)
    }

    func testCenteredColumnSurvivesTheRevealRule() throws {
        let centered = centerFocusedColumn(
            in: workspace(focusedColumn: 2), modes: [:], engine: engine, viewport: viewport
        )
        let planned = try planDisplayLayout(
            workspace: centered, modes: [:], engine: engine,
            viewport: viewport, display: viewport, otherDisplays: []
        )
        XCTAssertEqual(planned.workspace.viewportOffset, centered.viewportOffset)
        let frame = try XCTUnwrap(planned.layout.frames[id(3)])
        XCTAssertEqual(frame.midX, viewport.midX, accuracy: 0.001)
    }

    func testCenteringIsIdempotentAndIgnoresNonTiledWindows() {
        let once = centerFocusedColumn(
            in: workspace(focusedColumn: 2), modes: [:], engine: engine, viewport: viewport
        )
        XCTAssertEqual(
            centerFocusedColumn(in: once, modes: [:], engine: engine, viewport: viewport), once
        )
        // A floating first column leaves the strip; the focused column becomes index 1.
        let modes: [WindowID: WindowMode] = [id(1): .floating]
        let shifted = centerFocusedColumn(
            in: workspace(focusedColumn: 2), modes: modes, engine: engine, viewport: viewport
        )
        XCTAssertEqual(shifted.viewportOffset, (8 + 888 + 440) - 900, accuracy: 0.001)
    }

    func testNoFocusIsNoOp() {
        let empty = Workspace(id: WorkspaceID(1))
        XCTAssertEqual(centerFocusedColumn(in: empty, modes: [:], engine: engine, viewport: viewport), empty)
        var unfocused = workspace(focusedColumn: 2)
        unfocused.focusedWindow = nil
        XCTAssertEqual(
            centerFocusedColumn(in: unfocused, modes: [:], engine: engine, viewport: viewport), unfocused
        )
    }

    func testActionNameAndDefaultBinding() {
        XCTAssertEqual(parseActionName("center-column"), .centerColumn)
        XCTAssertTrue(validActionNames().contains("center-column"))
        XCTAssertEqual(
            HotkeyDispatcher().action(for: HotkeyCombo(modifiers: [.alt], key: "C")), .centerColumn
        )
    }
}
