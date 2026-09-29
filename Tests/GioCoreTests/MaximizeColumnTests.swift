import XCTest
@testable import GioCore

/// NC-02: maximize-column toggle restores the previous width spec.
final class MaximizeColumnTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func workspace(spec: ColumnWidthSpec = .standard) -> Workspace {
        Workspace(
            id: WorkspaceID(1),
            columns: [
                Column(id: ColumnID(1), width: 0, windows: [id(1)], widthSpec: spec),
                Column(id: ColumnID(2), width: 0, windows: [id(2)]),
            ],
            focusedColumn: 0,
            focusedWindow: id(1)
        )
    }

    func testMaximizeTakesFullWidthAndRemembersPrevious() {
        let maximized = toggleMaximizeFocusedColumn(in: workspace(spec: .proportion(0.66667)))
        XCTAssertEqual(maximized.columns[0].widthSpec, .proportion(1))
        XCTAssertEqual(maximized.columns[0].savedWidthSpec, .proportion(0.66667))
        XCTAssertEqual(maximized.columns[1], workspace().columns[1])
    }

    func testToggleTwiceRestoresExactlyWithoutDrift() {
        for spec in [ColumnWidthSpec.standard, .proportion(0.4), .points(512)] {
            let start = workspace(spec: spec)
            let back = toggleMaximizeFocusedColumn(in: toggleMaximizeFocusedColumn(in: start))
            XCTAssertEqual(back, start, "\(spec)")
        }
    }

    func testOtherWidthChangesClearSavedState() {
        let maximized = toggleMaximizeFocusedColumn(in: workspace(spec: .proportion(0.5)))
        let stepped = stepFocusedColumnWidth(
            in: maximized, by: -0.1, config: LayoutConfig(), viewportWidth: 1000
        )
        XCTAssertNil(stepped.columns[0].savedWidthSpec)
        // Toggling now maximizes again instead of restoring a stale width.
        let again = toggleMaximizeFocusedColumn(in: stepped)
        XCTAssertEqual(again.columns[0].widthSpec, .proportion(1))
        let cycled = switchPresetColumnWidth(
            in: maximized, presets: defaultPresetColumnWidths, config: LayoutConfig(), viewportWidth: 1000
        )
        XCTAssertNil(cycled.columns[0].savedWidthSpec)
    }

    func testEmptyWorkspaceIsNoOp() {
        let empty = Workspace(id: WorkspaceID(1))
        XCTAssertEqual(toggleMaximizeFocusedColumn(in: empty), empty)
    }

    func testActionNameAndDefaultBinding() {
        XCTAssertEqual(parseActionName("maximize-column"), .maximizeColumn)
        XCTAssertTrue(validActionNames().contains("maximize-column"))
        XCTAssertEqual(
            HotkeyDispatcher().action(for: HotkeyCombo(modifiers: [.alt], key: "F")), .maximizeColumn
        )
    }
}
