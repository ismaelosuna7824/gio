import XCTest
@testable import GioCore

/// WC-10: reveal compares content coordinates, and fractional column widths
/// account for padding and gaps (Niri proportion semantics), so clicking a
/// visible column never scrolls the strip.
final class RevealGeometryTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10 + pid_t(element), elementID: element)
    }

    private func workspace(columns count: Int, focus: Int, offset: CGFloat) -> Workspace {
        let columns = (0..<count).map { index in
            Column(id: ColumnID(UInt64(index + 1)), width: 0, windows: [id(UInt64(index + 1))])
        }
        return Workspace(
            id: WorkspaceID(1), columns: columns, focusedColumn: focus,
            focusedWindow: columns[focus].windows[0], viewportOffset: offset
        )
    }

    private let viewport = CGRect(x: 0, y: 0, width: 1800, height: 1100)

    private func engine(padding: CGFloat = 8, gap: CGFloat = 8) -> ScrollableLayoutEngine {
        ScrollableLayoutEngine(config: LayoutConfig(padding: padding, gap: gap))
    }

    // Live log: `focus adopt ... column=2 visible ... scroll=1824->0`. With the
    // strip scrolled, a visible column's screen x was read as a content x.
    func testFocusingAVisibleColumnInAScrolledStripDoesNotScroll() throws {
        let engine = engine()
        let scrolled = try planDisplayLayout(
            workspace: workspace(columns: 6, focus: 3, offset: 0), modes: [:],
            engine: engine, viewport: viewport, display: viewport, otherDisplays: []
        ).workspace
        XCTAssertGreaterThan(scrolled.viewportOffset, 0)

        // Column 2 sits next to the focused column 3, inside the viewport.
        var clicked = scrolled
        clicked.focusedColumn = 2
        clicked.focusedWindow = clicked.columns[2].windows[0]
        let layout = try engine.calculate(workspace: clicked, viewport: viewport)
        let frame = try XCTUnwrap(layout.frames[id(3)])
        XCTAssertTrue(viewport.contains(frame), "precondition: column 2 is visible")

        XCTAssertNil(revealOffset(workspace: clicked, layout: layout, viewport: viewport, edgeMargin: 8))
    }

    func testRevealWorksInAViewportThatDoesNotStartAtZero() throws {
        let shifted = CGRect(x: 1800, y: 0, width: 1800, height: 1100)
        let engine = engine()
        let ws = workspace(columns: 4, focus: 0, offset: 0)
        let layout = try engine.calculate(workspace: ws, viewport: shifted)
        XCTAssertNil(revealOffset(workspace: ws, layout: layout, viewport: shifted, edgeMargin: 8))
    }

    // Live log: `column=1 visible ... scroll=0->16`. Two half-width columns
    // must fit the viewport exactly, padding and gap included.
    func testTwoHalfColumnsFitTheViewportExactly() throws {
        let engine = engine()
        let ws = workspace(columns: 2, focus: 1, offset: 0)
        let layout = try engine.calculate(workspace: ws, viewport: viewport)
        XCTAssertEqual(layout.contentWidth, viewport.width, accuracy: 0.5)
        XCTAssertNil(revealOffset(workspace: ws, layout: layout, viewport: viewport, edgeMargin: 8))
    }

    func testFractionResolvesWithNiriProportionSemantics() {
        var config = GioConfig()
        config.layout.padding = 12
        config.layout.gaps = 8
        config.layout.defaultColumnWidthFraction = 0.5
        // 0.5 * (1000 - 2*12 + 8) - 8 = 484; 2*484 + 8 + 2*12 = 1000.
        XCTAssertEqual(config.makeLayoutConfig().resolvedWidth(of: .standard, viewportWidth: 1000), 484)
        config.layout.defaultColumnWidthFraction = 1
        XCTAssertEqual(config.makeLayoutConfig().resolvedWidth(of: .standard, viewportWidth: 1000), 976)
    }

    // Live 2026-10-08 (Xcode, `Alt+F` on the middle column): the maximized
    // column was scrolled in minimally, flush with the right edge of the
    // screen and twice the padding on the left, until a focus round trip
    // re-centered it. A revealed column keeps the padding to the edge.
    func testAMaximizedColumnRevealedFromEitherSideKeepsThePadding() throws {
        let engine = engine(padding: 8, gap: 8)
        for (offset, label) in [(CGFloat(0), "from the left"), (CGFloat(3000), "from the right")] {
            var ws = workspace(columns: 4, focus: 1, offset: offset)
            ws.columns[1].widthSpec = .proportion(1)
            let plan = try planDisplayLayout(
                workspace: ws, modes: [:], engine: engine, viewport: viewport, display: viewport, otherDisplays: []
            )
            let frame = try XCTUnwrap(plan.layout.frames[id(2)])
            XCTAssertEqual(frame.minX, viewport.minX + 8, accuracy: 0.5, label)
            XCTAssertEqual(frame.maxX, viewport.maxX - 8, accuracy: 0.5, label)
        }
    }

    func testANeighbourScrolledInStopsAtThePaddingNotTheScreenEdge() throws {
        let engine = engine(padding: 8, gap: 8)
        // Columns 0 and 1 fill the screen; focusing column 2 scrolls right.
        let ws = workspace(columns: 4, focus: 2, offset: 0)
        let plan = try planDisplayLayout(
            workspace: ws, modes: [:], engine: engine, viewport: viewport, display: viewport, otherDisplays: []
        )
        let revealed = try XCTUnwrap(plan.layout.frames[id(3)])
        XCTAssertEqual(revealed.maxX, viewport.maxX - 8, accuracy: 0.5)
        // The previous column is now exactly in view on the left, padding included.
        let previous = try XCTUnwrap(plan.layout.frames[id(2)])
        XCTAssertEqual(previous.minX, viewport.minX + 8, accuracy: 0.5)
    }
}
