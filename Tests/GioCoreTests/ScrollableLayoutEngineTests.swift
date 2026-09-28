import XCTest
@testable import GioCore

/// Plan §9 mandatory coverage: single window/column, vertical stacks,
/// multiple columns, sizes, gaps, padding, viewport, overflow, insertion
/// and deletion. NOT BSP: appending a column never moves columns left of it.
final class ScrollableLayoutEngineTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let engine = ScrollableLayoutEngine()

    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private func column(
        id: UInt64 = 1,
        width: CGFloat = 0,
        windows: [WindowID],
        focused: Int = 0
    ) -> Column {
        Column(id: ColumnID(id), width: width, windows: windows, focusedWindowIndex: focused)
    }

    func testSingleWindowUsesDefaultWidth() throws {
        let workspace = Workspace(
            id: WorkspaceID(1), columns: [column(windows: [id(1)])]
        )
        let result = try engine.calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(result.frames, [id(1): CGRect(x: 8, y: 8, width: 500, height: 784)])
        XCTAssertEqual(result.contentWidth, 516)
        XCTAssertEqual(result.viewportOffset, 0)
    }

    func testMultipleColumnsWithExplicitWidths() throws {
        let workspace = Workspace(
            id: WorkspaceID(1),
            columns: [
                column(id: 1, width: 300, windows: [id(1)]),
                column(id: 2, width: 400, windows: [id(2)]),
            ]
        )
        let result = try engine.calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(result.frames[id(1)], CGRect(x: 8, y: 8, width: 300, height: 784))
        XCTAssertEqual(result.frames[id(2)], CGRect(x: 316, y: 8, width: 400, height: 784))
        XCTAssertEqual(result.contentWidth, 724)
    }

    func testVerticalStackSharesHeightEqually() throws {
        let workspace = Workspace(
            id: WorkspaceID(1),
            columns: [column(width: 400, windows: [id(1), id(2), id(3)])]
        )
        let result = try engine.calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(result.frames[id(1)], CGRect(x: 8, y: 8, width: 400, height: 256))
        XCTAssertEqual(result.frames[id(2)], CGRect(x: 8, y: 272, width: 400, height: 256))
        XCTAssertEqual(result.frames[id(3)], CGRect(x: 8, y: 536, width: 400, height: 256))
    }

    func testZeroGapsAndPaddingTileExactly() throws {
        let tight = ScrollableLayoutEngine(config: LayoutConfig(padding: 0, gap: 0))
        let workspace = Workspace(
            id: WorkspaceID(1),
            columns: [
                column(id: 1, width: 500, windows: [id(1)]),
                column(id: 2, width: 500, windows: [id(2)]),
            ]
        )
        let result = try tight.calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(result.frames[id(1)], CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(result.frames[id(2)], CGRect(x: 500, y: 0, width: 500, height: 800))
        XCTAssertEqual(result.contentWidth, 1000)
        XCTAssertEqual(result.viewportOffset, 0)
    }

    func testOverflowClampsOffsetAndShiftsFrames() throws {
        let workspace = Workspace(
            id: WorkspaceID(1),
            columns: [
                column(id: 1, width: 400, windows: [id(1)]),
                column(id: 2, width: 400, windows: [id(2)]),
                column(id: 3, width: 400, windows: [id(3)]),
            ],
            viewportOffset: 100
        )
        let result = try engine.calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(result.contentWidth, 1232)
        XCTAssertEqual(result.viewportOffset, 100)
        XCTAssertEqual(result.frames[id(1)]?.origin.x, -92)
        var beyond = workspace
        beyond.viewportOffset = 500
        let clamped = try engine.calculate(workspace: beyond, viewport: viewport)
        XCTAssertEqual(clamped.viewportOffset, 232)
    }

    func testOffsetResetsWhenContentFits() throws {
        let workspace = Workspace(
            id: WorkspaceID(1),
            columns: [column(width: 300, windows: [id(1)])],
            viewportOffset: 500
        )
        let result = try engine.calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(result.viewportOffset, 0)
        XCTAssertEqual(result.frames[id(1)]?.origin.x, 8)
    }

    func testAppendingColumnKeepsLeftFramesStable() throws {
        let left = [
            column(id: 1, width: 300, windows: [id(1)]),
            column(id: 2, width: 300, windows: [id(2)]),
        ]
        let before = try engine.calculate(
            workspace: Workspace(id: WorkspaceID(1), columns: left), viewport: viewport
        )
        let after = try engine.calculate(
            workspace: Workspace(
                id: WorkspaceID(1),
                columns: left + [column(id: 3, width: 300, windows: [id(3)])]
            ),
            viewport: viewport
        )
        XCTAssertEqual(after.frames[id(1)], before.frames[id(1)])
        XCTAssertEqual(after.frames[id(2)], before.frames[id(2)])
        XCTAssertEqual(after.frames[id(3)]?.origin.x, 624)
    }

    func testRemovingMiddleColumnShiftsRightOnesLeft() throws {
        let workspace = Workspace(
            id: WorkspaceID(1),
            columns: [
                column(id: 1, width: 300, windows: [id(1)]),
                column(id: 3, width: 300, windows: [id(3)]),
            ]
        )
        let result = try engine.calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.origin.x, 8)
        XCTAssertEqual(result.frames[id(3)]?.origin.x, 316)
        XCTAssertEqual(result.contentWidth, 624)
    }

    func testNarrowColumnClampsToMinimum() throws {
        let workspace = Workspace(
            id: WorkspaceID(1), columns: [column(width: 50, windows: [id(1)])]
        )
        let result = try engine.calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.size.width, 200)
    }

    func testEmptyColumnsContributeNothing() throws {
        let workspace = Workspace(
            id: WorkspaceID(1),
            columns: [column(id: 1, windows: []), column(id: 2, width: 300, windows: [id(1)])],
            viewportOffset: 40
        )
        let result = try engine.calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames[id(1)]?.origin.x, 8)
        XCTAssertEqual(result.contentWidth, 316)
        XCTAssertEqual(result.viewportOffset, 0)
    }

    func testViewportOriginOffsetsFrames() throws {
        let shifted = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let workspace = Workspace(
            id: WorkspaceID(1), columns: [column(width: 300, windows: [id(1)])]
        )
        let result = try engine.calculate(workspace: workspace, viewport: shifted)
        XCTAssertEqual(result.frames[id(1)], CGRect(x: 108, y: 58, width: 300, height: 784))
    }

    func testNonFiniteOffsetTreatedAsZero() throws {
        let workspace = Workspace(
            id: WorkspaceID(1),
            columns: [column(width: 300, windows: [id(1)])],
            viewportOffset: .nan
        )
        let result = try engine.calculate(workspace: workspace, viewport: viewport)
        XCTAssertEqual(result.viewportOffset, 0)
    }

    func testInvalidInputsThrow() {
        let workspace = Workspace(
            id: WorkspaceID(1), columns: [column(width: 300, windows: [id(1)])]
        )
        XCTAssertThrowsError(
            try engine.calculate(workspace: workspace, viewport: .zero)
        ) { XCTAssertEqual($0 as? LayoutError, .invalidViewport) }
        let badConfig = ScrollableLayoutEngine(config: LayoutConfig(padding: 0, gap: -4))
        XCTAssertThrowsError(
            try badConfig.calculate(workspace: workspace, viewport: viewport)
        ) { XCTAssertEqual($0 as? LayoutError, .invalidConfiguration) }
        let greedy = ScrollableLayoutEngine(config: LayoutConfig(padding: 500, gap: 8))
        XCTAssertThrowsError(
            try greedy.calculate(workspace: workspace, viewport: viewport)
        ) { XCTAssertEqual($0 as? LayoutError, .invalidViewport) }
    }
}
