import XCTest
@testable import GioCore

/// Plan §13: width adjust/reset, height factor/reset, invalid NO-OP, plus
/// engine distribution over weights.
final class WindowResizeTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func workspace() -> Workspace {
        Workspace(
            id: WorkspaceID(1),
            columns: [Column(id: ColumnID(1), width: 300, windows: [id(1), id(2)])],
            focusedColumn: 0,
            focusedWindow: id(1)
        )
    }

    func testResizeColumnWidthAdjustsAndFloors() {
        let grown = resizeFocusedColumnWidth(in: workspace(), delta: 50)
        XCTAssertEqual(grown.columns[0].width, 350)
        let shrunk = resizeFocusedColumnWidth(in: workspace(), delta: -500)
        XCTAssertEqual(shrunk.columns[0].width, 0)
    }

    func testResetColumnWidthRestoresDefault() {
        let grown = resizeFocusedColumnWidth(in: workspace(), delta: 120)
        XCTAssertEqual(resetFocusedColumnWidth(in: grown).columns[0].width, 0)
    }

    func testResizeHeightCompoundsAndFloors() {
        let once = resizeFocusedWindowHeight(in: workspace(), factor: 2)
        XCTAssertEqual(once.columns[0].heightWeights[id(1)], 2)
        let twice = resizeFocusedWindowHeight(in: once, factor: 1.5)
        XCTAssertEqual(twice.columns[0].heightWeights[id(1)], 3)
        let tiny = resizeFocusedWindowHeight(in: workspace(), factor: 0.01)
        XCTAssertEqual(tiny.columns[0].heightWeights[id(1)], 0.2)
        XCTAssertEqual(
            resizeFocusedWindowHeight(in: workspace(), factor: -1), workspace()
        )
    }

    func testResetHeightRemovesEntry() {
        let grown = resizeFocusedWindowHeight(in: workspace(), factor: 2)
        let reset = resetFocusedWindowHeight(in: grown)
        XCTAssertNil(reset.columns[0].heightWeights[id(1)])
        XCTAssertEqual(reset.columns[0].heightWeights.count, 0)
    }

    func testInvalidStatesAreNoOp() {
        let empty = Workspace(id: WorkspaceID(9))
        XCTAssertEqual(resizeFocusedColumnWidth(in: empty, delta: 10), empty)
        XCTAssertEqual(resetFocusedColumnWidth(in: empty), empty)
        XCTAssertEqual(resizeFocusedWindowHeight(in: empty, factor: 2), empty)
        XCTAssertEqual(resetFocusedWindowHeight(in: empty), empty)
    }

    func testEngineDistributesHeightByWeight() throws {
        let engine = ScrollableLayoutEngine()
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var weighted = workspace()
        weighted = resizeFocusedWindowHeight(in: weighted, factor: 3)
        let result = try engine.calculate(workspace: weighted, viewport: viewport)
        // Usable 784 minus one 8pt gap = 776, weights 3:1 → 582 (top) and 194 (bottom).
        XCTAssertEqual(result.frames[id(1)], CGRect(x: 8, y: 210, width: 300, height: 582))
        XCTAssertEqual(result.frames[id(2)], CGRect(x: 8, y: 8, width: 300, height: 194))
    }

    func testEngineDefaultsStayEqual() throws {
        let engine = ScrollableLayoutEngine()
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let result = try engine.calculate(workspace: workspace(), viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.height, 388)
        XCTAssertEqual(result.frames[id(2)]?.height, 388)
    }
}
