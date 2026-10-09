import XCTest
@testable import GioCore

/// NC-08: niri window heights in a stacked column. Heights are relative
/// `heightWeights`; the actions compute the weight that gives the focused
/// window the wanted height of the column (same proportion/points rule as
/// widths) and never squeeze any window below `minimumWindowHeight`.
final class WindowHeightTests: XCTestCase {
    private let viewportHeight: CGFloat = 1000
    private let config = LayoutConfig(padding: 8, gap: 8)
    private let presets = defaultPresetWindowHeights

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    /// One stacked column of `count` windows (plus a lone neighbour), the
    /// window at `focused` focused.
    private func workspace(count: Int = 2, focused: Int = 0, weights: [CGFloat] = []) -> Workspace {
        let windows = (1...count).map { id(UInt64($0)) }
        var column = Column(id: ColumnID(1), width: 0, windows: windows, focusedWindowIndex: focused)
        for (window, weight) in zip(windows, weights) {
            column.heightWeights[window] = weight
        }
        return Workspace(
            id: WorkspaceID(1),
            columns: [column, Column(id: ColumnID(2), width: 0, windows: [id(99)])],
            focusedColumn: 0,
            focusedWindow: windows[focused]
        )
    }

    /// Heights the engine gives the first column's windows.
    private func heights(_ workspace: Workspace) throws -> [CGFloat] {
        let result = try ScrollableLayoutEngine(config: config).calculate(
            workspace: workspace, viewport: CGRect(x: 0, y: 0, width: 1600, height: viewportHeight)
        )
        return workspace.columns[0].windows.map { result.frames[$0]!.height }
    }

    private func preset(_ workspace: Workspace) -> Workspace {
        switchPresetWindowHeight(in: workspace, presets: presets, config: config, viewportHeight: viewportHeight)
    }

    private func step(_ workspace: Workspace, _ fraction: CGFloat) -> Workspace {
        stepFocusedWindowHeight(in: workspace, by: fraction, config: config, viewportHeight: viewportHeight)
    }

    func testDefaultPresetHeightsMatchTheWidthPresets() {
        XCTAssertEqual(defaultPresetWindowHeights, [.proportion(0.33333), .proportion(0.5), .proportion(0.66667)])
        XCTAssertEqual(minimumWindowHeight, 100)
    }

    func testPresetCycleWithStackedWindowsGoesToTheNextTallerAndWraps() throws {
        // Strip 1000 - 16 + 8 = 992: thirds 322.66, half 488, two thirds 653.34.
        let start = workspace()
        XCTAssertEqual(try heights(start)[0], 488, accuracy: 0.01)
        let taller = preset(start)
        XCTAssertEqual(try heights(taller)[0], 653.34, accuracy: 0.05)
        XCTAssertEqual(try heights(taller)[1], 976 - 653.34, accuracy: 0.05, "the other window takes the rest")
        let wrapped = preset(taller)
        XCTAssertEqual(try heights(wrapped)[0], 322.66, accuracy: 0.05)
        let half = preset(wrapped)
        XCTAssertEqual(try heights(half)[0], 488, accuracy: 0.05)
        XCTAssertEqual(taller.columns[1], start.columns[1], "other columns untouched")
        XCTAssertEqual(taller.focusedWindow, start.focusedWindow)
    }

    func testPresetInPointsAndOthersKeepTheirRelativeShares() throws {
        let start = workspace(count: 3, focused: 0, weights: [1, 2, 1])
        let next = switchPresetWindowHeight(
            in: start, presets: [.points(300)], config: config, viewportHeight: viewportHeight
        )
        let result = try heights(next)
        XCTAssertEqual(result[0], 300, accuracy: 0.01)
        XCTAssertEqual(result[1] / result[2], 2, accuracy: 0.001, "the others keep their 2:1 split")
    }

    func testStepMovesTenPercentOfTheColumn() throws {
        let start = workspace()
        XCTAssertEqual(try heights(step(start, 0.1))[0], 488 + 99.2, accuracy: 0.01)
        XCTAssertEqual(try heights(step(start, -0.1))[0], 488 - 99.2, accuracy: 0.01)
    }

    func testHeightsClampSoEveryWindowKeepsTheMinimum() throws {
        // Three windows: 1000 - 16 - 16 = 968 to share.
        var grown = workspace(count: 3, focused: 1)
        for _ in 0..<12 {
            grown = step(grown, 0.1)
        }
        let tall = try heights(grown)
        XCTAssertEqual(tall[1], 968 - 200, accuracy: 0.01)
        XCTAssertEqual(tall[0], 100, accuracy: 0.01)
        XCTAssertEqual(tall[2], 100, accuracy: 0.01)
        XCTAssertEqual(step(grown, 0.1), grown, "already at the ceiling: a no-op")

        var shrunk = workspace(count: 3, focused: 1)
        for _ in 0..<12 {
            shrunk = step(shrunk, -0.1)
        }
        XCTAssertEqual(try heights(shrunk)[1], 100, accuracy: 0.01)

        let huge = switchPresetWindowHeight(
            in: workspace(count: 3), presets: [.points(5000)], config: config, viewportHeight: viewportHeight
        )
        XCTAssertEqual(try heights(huge)[0], 768, accuracy: 0.01, "a preset taller than the column clamps")
    }

    func testLoneWindowEmptyColumnAndCrampedColumnAreNoOps() {
        let lone = Workspace(
            id: WorkspaceID(1), columns: [Column(id: ColumnID(1), width: 0, windows: [id(1)])],
            focusedColumn: 0, focusedWindow: id(1)
        )
        XCTAssertEqual(preset(lone), lone)
        XCTAssertEqual(step(lone, 0.1), lone)
        let empty = Workspace(id: WorkspaceID(1))
        XCTAssertEqual(preset(empty), empty)
        XCTAssertEqual(step(empty, -0.1), empty)
        XCTAssertEqual(resetWindowHeights(in: empty), empty)
        let cramped = workspace(count: 3)
        XCTAssertEqual(
            switchPresetWindowHeight(in: cramped, presets: presets, config: config, viewportHeight: 300), cramped,
            "the column cannot give every window the minimum"
        )
        XCTAssertEqual(
            switchPresetWindowHeight(in: workspace(), presets: [], config: config, viewportHeight: viewportHeight),
            workspace()
        )
    }

    func testResetGivesEveryWindowAnEqualShare() throws {
        let tall = preset(workspace(count: 3, focused: 2, weights: [3, 1, 1]))
        let reset = resetWindowHeights(in: tall)
        XCTAssertEqual(reset.columns[0].heightWeights, [:])
        let result = try heights(reset)
        XCTAssertEqual(result[0], result[1], accuracy: 0.001)
        XCTAssertEqual(result[1], result[2], accuracy: 0.001)
        XCTAssertEqual(reset.columns[1], tall.columns[1])
        XCTAssertEqual(resetWindowHeights(in: reset), reset, "equal shares already: a no-op")
    }
}
