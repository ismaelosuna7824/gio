import XCTest
@testable import GioCore

/// Plan §17: floating excluded from layout, mode lifecycle, fullscreen
/// capture/restore. Focus reaches floating windows by construction (focus is
/// ID-based and never consults modes).
final class WindowModeTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func window(_ element: UInt64, mode: WindowMode = .tiled) -> ManagedWindow {
        ManagedWindow(
            id: id(element),
            pid: 10,
            application: "Code",
            title: "editor",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            mode: mode
        )
    }

    private func workspace() -> Workspace {
        Workspace(
            id: WorkspaceID(1),
            columns: [
                Column(id: ColumnID(1), width: 300, windows: [id(1), id(2)]),
                Column(id: ColumnID(2), width: 300, windows: [id(3)]),
            ]
        )
    }

    func testFilterKeepsOnlyTiled() {
        let modes: [WindowID: WindowMode] = [id(1): .tiled, id(2): .floating, id(3): .fullscreen]
        let filtered = tilingWorkspace(from: workspace(), modes: modes)
        XCTAssertEqual(filtered.columns.count, 1)
        XCTAssertEqual(filtered.columns[0].windows, [id(1)])
    }

    func testFilterDropsEmptiedColumnsAndClampsFocus() {
        var full = workspace()
        full.focusedColumn = 1
        let modes: [WindowID: WindowMode] = [id(1): .floating, id(2): .floating]
        let filtered = tilingWorkspace(from: full, modes: modes)
        XCTAssertEqual(filtered.columns.count, 1)
        XCTAssertEqual(filtered.columns[0].windows, [id(3)])
        XCTAssertEqual(filtered.focusedColumn, 0)
    }

    func testFilterUnknownIDsCountAsTiled() {
        let filtered = tilingWorkspace(from: workspace(), modes: [:])
        XCTAssertEqual(filtered.columns.count, 2)
    }

    func testFilterAllFloatingYieldsEmpty() throws {
        let modes: [WindowID: WindowMode] = [id(1): .floating, id(2): .floating, id(3): .floating]
        let filtered = tilingWorkspace(from: workspace(), modes: modes)
        XCTAssertTrue(filtered.columns.isEmpty)
        let engine = ScrollableLayoutEngine()
        let result = try engine.calculate(
            workspace: filtered, viewport: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertEqual(result.contentWidth, 0)
    }

    func testSetModeAndUnknownThrows() throws {
        let registry = WindowRegistry()
        try registry.register(window(1))
        try registry.setMode(.floating, for: id(1))
        XCTAssertEqual(registry.find(id(1))!.mode, .floating)
        XCTAssertThrowsError(try registry.setMode(.tiled, for: id(9))) { error in
            XCTAssertEqual(error as? WindowRegistryError, .unknown(id(9)))
        }
    }

    func testToggleFloating() throws {
        let registry = WindowRegistry()
        try registry.register(window(1))
        XCTAssertEqual(try registry.toggleFloating(for: id(1)), .floating)
        XCTAssertEqual(try registry.toggleFloating(for: id(1)), .tiled)
        try registry.setMode(.fullscreen, for: id(1))
        XCTAssertEqual(try registry.toggleFloating(for: id(1)), .tiled)
        XCTAssertThrowsError(try registry.toggleFloating(for: id(9)))
    }

    func testFullscreenCapturesAndRestores() throws {
        let registry = WindowRegistry()
        try registry.register(window(1))
        let full = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let record = try registry.beginFullscreen(id: id(1), frame: full)
        XCTAssertEqual(record.previousFrame, CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(record.previousMode, .tiled)
        XCTAssertEqual(registry.find(id(1))!.mode, .fullscreen)
        XCTAssertEqual(registry.find(id(1))!.frame, full)
        try registry.endFullscreen(record)
        XCTAssertEqual(registry.find(id(1))!.mode, .tiled)
        XCTAssertEqual(registry.find(id(1))!.frame, CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testFullscreenUnknownThrows() {
        let registry = WindowRegistry()
        XCTAssertThrowsError(
            try registry.beginFullscreen(id: id(1), frame: .zero)
        )
        XCTAssertThrowsError(
            try registry.endFullscreen(FullscreenRecord(
                id: id(1), previousFrame: .zero, previousMode: .tiled
            ))
        )
    }
}
