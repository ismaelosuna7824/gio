import CoreGraphics
import XCTest
@testable import GioCore

/// MD-01: Option + right-drag resizes the tiled window under the pointer on
/// both axes; Option + left-drag moves it (swap on a tile's center, a new
/// column on its side edges, into its column on its top or bottom edge).
final class MouseDragTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func id(_ n: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: n)
    }

    /// Columns of 400 pt: screen x 8-408, 416-816, 824-1224 at offset 0.
    private func workspace(_ columns: [[UInt64]], width: CGFloat = 400, focused: UInt64 = 1) -> Workspace {
        Workspace(
            id: WorkspaceID(1),
            columns: columns.enumerated().map { index, windows in
                Column(id: ColumnID(UInt64(index + 1)), width: width, windows: windows.map(id))
            },
            focusedColumn: columns.firstIndex { $0.contains(focused) } ?? 0, focusedWindow: id(focused)
        )
    }

    private func surface(
        _ workspace: Workspace, modes: [WindowID: WindowMode] = [:], config: LayoutConfig = LayoutConfig(padding: 8, gap: 8)
    ) -> GestureSurface {
        GestureSurface(
            display: DisplayID(1), workspace: workspace, modes: modes, engine: ScrollableLayoutEngine(config: config),
            viewport: viewport, displayFrame: viewport, otherDisplays: [], centering: false
        )
    }

    private func frames(_ workspace: Workspace, _ surface: GestureSurface) throws -> [WindowID: CGRect] {
        try surface.engine.calculate(workspace: workspace, viewport: viewport).frames
    }

    // MARK: - Trigger

    func testTheModifierAndButtonChooseTheDrag() {
        let settings = MouseDragSettings(move: true, resize: true, modifiers: [.alt])
        func down(_ button: MouseButton, _ modifiers: Set<HotkeyModifier>) -> MouseButtonEvent {
            MouseButtonEvent(phase: .down, button: button, location: .zero, modifiers: modifiers)
        }
        XCTAssertEqual(mouseDragKind(for: down(.left, [.alt]), settings: settings), .move)
        XCTAssertEqual(mouseDragKind(for: down(.right, [.alt]), settings: settings), .resize)
        XCTAssertNil(mouseDragKind(for: down(.left, [.alt, .shift]), settings: settings), "exact modifiers only")
        XCTAssertNil(mouseDragKind(for: down(.left, []), settings: settings))
        XCTAssertNil(mouseDragKind(for: down(.other, [.alt]), settings: settings))
        XCTAssertNil(mouseDragKind(
            for: MouseButtonEvent(phase: .dragged, button: .left, location: .zero, modifiers: [.alt]), settings: settings
        ))
        let resizeOnly = MouseDragSettings(move: false, resize: true, modifiers: [.alt])
        XCTAssertNil(mouseDragKind(for: down(.left, [.alt]), settings: resizeOnly))
        XCTAssertNil(mouseDragKind(for: down(.left, []), settings: MouseDragSettings(move: true, resize: true, modifiers: [])),
                     "no modifier would take every click")
    }

    // MARK: - Resize

    func testRightHalfGrabGrowsTheRightEdge() throws {
        let start = surface(workspace([[1], [2], [3]]))
        let resize = try XCTUnwrap(beginMouseResize(start, window: id(1), at: CGPoint(x: 300, y: 400)))
        let next = mouseResized(resize, surface: start, to: CGPoint(x: 400, y: 400))
        let laidOut = try frames(next, start)
        XCTAssertEqual(laidOut[id(1)]?.minX ?? 0, 8, accuracy: 0.5)
        XCTAssertEqual(laidOut[id(1)]?.width ?? 0, 500, accuracy: 0.5)
        XCTAssertEqual(laidOut[id(2)]?.minX ?? 0, 516, accuracy: 0.5)
        XCTAssertEqual(next.fillPausedAtColumnCount, 3, "a width set by hand pauses fill-empty-space")
        XCTAssertEqual(next.columns[1].widthSpec, start.workspace.columns[1].widthSpec)
    }

    func testLeftHalfGrabGrowsTheLeftEdgeAndKeepsTheRightOne() throws {
        let start = surface(workspace([[1], [2], [3]]))
        let resize = try XCTUnwrap(beginMouseResize(start, window: id(2), at: CGPoint(x: 450, y: 400)))
        let next = mouseResized(resize, surface: start, to: CGPoint(x: 350, y: 400))
        let laidOut = try frames(next, start)
        XCTAssertEqual(laidOut[id(2)]?.width ?? 0, 500, accuracy: 0.5)
        XCTAssertEqual(laidOut[id(2)]?.maxX ?? 0, 816, accuracy: 0.5)
    }

    func testWidthStopsAtTheMinimumAndTheStrip() throws {
        let start = surface(workspace([[1], [2]]))
        let resize = try XCTUnwrap(beginMouseResize(start, window: id(1), at: CGPoint(x: 300, y: 400)))
        let narrow = try frames(mouseResized(resize, surface: start, to: CGPoint(x: -500, y: 400)), start)
        XCTAssertEqual(narrow[id(1)]?.width ?? 0, LayoutConfig().minimumColumnWidth, accuracy: 0.5)
        let wide = try frames(mouseResized(resize, surface: start, to: CGPoint(x: 3000, y: 400)), start)
        XCTAssertEqual(wide[id(1)]?.width ?? 0, 984, accuracy: 0.5)
    }

    func testAStackedWindowResizesItsHeightToo() throws {
        let start = surface(workspace([[1, 4], [2]]))
        let before = try frames(start.workspace, start)
        let frame = try XCTUnwrap(before[id(1)])
        let lowEdge = frame.minY + 10 < frame.midY
        XCTAssertTrue(lowEdge)
        // Grab near the bottom edge (Cocoa: low y) and pull it down 50 pt.
        let grab = CGPoint(x: frame.maxX - 20, y: frame.minY + 10)
        let resize = try XCTUnwrap(beginMouseResize(start, window: id(1), at: grab))
        let next = mouseResized(resize, surface: start, to: CGPoint(x: grab.x + 40, y: grab.y - 50))
        let laidOut = try frames(next, start)
        XCTAssertEqual(laidOut[id(1)]?.height ?? 0, frame.height + 50, accuracy: 1)
        XCTAssertEqual(laidOut[id(1)]?.width ?? 0, frame.width + 40, accuracy: 0.5)
        XCTAssertEqual(laidOut[id(4)]?.height ?? 0, (before[id(4)]?.height ?? 0) - 50, accuracy: 1)
    }

    func testALoneWindowInItsColumnKeepsItsHeight() throws {
        let start = surface(workspace([[1], [2]]))
        let resize = try XCTUnwrap(beginMouseResize(start, window: id(1), at: CGPoint(x: 300, y: 100)))
        let next = mouseResized(resize, surface: start, to: CGPoint(x: 300, y: 0))
        XCTAssertEqual(next.columns[0].heightWeights, [:])
    }

    func testFilledWidthsAreWhatTheResizeStartsFrom() throws {
        let config = LayoutConfig(padding: 8, gap: 8, fillEmptySpace: true)
        let start = surface(workspace([[1], [2]], width: 300), config: config)
        let filled = try frames(start.workspace, start)
        XCTAssertEqual(filled[id(1)]?.width ?? 0, 488, accuracy: 0.5)
        let resize = try XCTUnwrap(beginMouseResize(start, window: id(1), at: CGPoint(x: 300, y: 400)))
        let still = try frames(mouseResized(resize, surface: start, to: CGPoint(x: 300, y: 400)), start)
        XCTAssertEqual(still[id(1)]?.width ?? 0, 488, accuracy: 0.5)
        XCTAssertEqual(still[id(2)]?.width ?? 0, 488, accuracy: 0.5, "the neighbour keeps the width it showed")
    }

    func testNoResizeOffTheStrip() {
        XCTAssertNil(beginMouseResize(surface(workspace([[1], [2]])), window: id(9), at: CGPoint(x: 300, y: 400)))
        XCTAssertNil(beginMouseResize(
            surface(workspace([[1], [2]]), modes: [id(1): .floating]), window: id(1), at: CGPoint(x: 300, y: 400)
        ))
        XCTAssertNil(beginMouseResize(
            surface(workspace([[1], [2]]), modes: [id(2): .fullscreen]), window: id(1), at: CGPoint(x: 300, y: 400)
        ))
        var dwindle = workspace([[1], [2]])
        dwindle.layout = .dwindle
        XCTAssertNil(beginMouseResize(surface(dwindle), window: id(1), at: CGPoint(x: 300, y: 400)))
    }

    // MARK: - Move

    func testDropZonesOfATile() {
        let tile = CGRect(x: 8, y: 8, width: 400, height: 784)
        let frames = [id(1): tile, id(2): CGRect(x: 416, y: 8, width: 400, height: 784)]
        func target(_ x: CGFloat, _ y: CGFloat) -> MouseDropTarget? {
            mouseDropTarget(at: CGPoint(x: x, y: y), dragged: id(2), frames: frames)
        }
        XCTAssertEqual(target(20, 400), .newColumn(beside: id(1), after: false))
        XCTAssertEqual(target(395, 400), .newColumn(beside: id(1), after: true))
        XCTAssertEqual(target(200, 400), .swap(id(1)))
        XCTAssertEqual(target(200, 780), .stack(beside: id(1), below: false), "Cocoa: a high y is the top edge")
        XCTAssertEqual(target(200, 20), .stack(beside: id(1), below: true))
        XCTAssertNil(target(600, 400), "over the dragged window itself")
        XCTAssertNil(target(412, 400), "in a gap")
    }

    func testSwapTradesPlacesAndTheFocusFollowsTheWindow() {
        let start = workspace([[1], [2], [3]], focused: 1)
        let next = movingWindow(id(1), to: .swap(id(3)), in: start)
        XCTAssertEqual(next.columns.map { $0.windows }, [[id(3)], [id(2)], [id(1)]])
        XCTAssertEqual(next.columns.map(\.id), start.columns.map(\.id), "widths stay with the columns")
        XCTAssertEqual(next.focusedWindow, id(1))
        XCTAssertEqual(next.focusedColumn, 2)
    }

    func testSwapInsideAColumnCarriesTheHeights() {
        var start = workspace([[1, 4]])
        start.columns[0].heightWeights = [id(1): 2]
        let next = movingWindow(id(1), to: .swap(id(4)), in: start)
        XCTAssertEqual(next.columns[0].windows, [id(4), id(1)])
        XCTAssertEqual(next.columns[0].heightWeights, [id(1): 2])
        XCTAssertEqual(next.columns[0].focusedWindowIndex, 1)
    }

    func testAStackedWindowOpensANewColumnWithItsColumnsWidth() {
        var start = workspace([[1], [2, 5], [3]])
        start.columns[1].widthSpec = .proportion(0.7)
        let next = movingWindow(id(5), to: .newColumn(beside: id(1), after: false), in: start)
        XCTAssertEqual(next.columns.map { $0.windows }, [[id(5)], [id(1)], [id(2)], [id(3)]])
        XCTAssertEqual(next.columns[0].widthSpec, .proportion(0.7))
        XCTAssertEqual(Set(next.columns.map(\.id)).count, 4, "the new column has its own id")
    }

    func testALoneWindowCarriesItsColumn() {
        var start = workspace([[1], [2], [3]], focused: 2)
        start.columns[0].widthSpec = .proportion(0.3)
        let next = movingWindow(id(1), to: .newColumn(beside: id(3), after: true), in: start)
        XCTAssertEqual(next.columns.map { $0.windows }, [[id(2)], [id(3)], [id(1)]])
        XCTAssertEqual(next.columns[2].widthSpec, .proportion(0.3))
        XCTAssertEqual(next.focusedColumn, 0, "the focus stays on window 2")
    }

    func testStackingJoinsTheTargetColumnAboveOrBelow() {
        let start = workspace([[1], [2], [3]])
        let below = movingWindow(id(1), to: .stack(beside: id(2), below: true), in: start)
        XCTAssertEqual(below.columns.map { $0.windows }, [[id(2), id(1)], [id(3)]])
        XCTAssertEqual(below.focusedColumn, 0)
        XCTAssertEqual(below.columns[0].focusedWindowIndex, 1)
        let above = movingWindow(id(3), to: .stack(beside: id(2), below: false), in: start)
        XCTAssertEqual(above.columns.map { $0.windows }, [[id(1)], [id(3), id(2)]])
    }

    func testDroppingOnItselfChangesNothing() {
        let start = workspace([[1, 4], [2]])
        XCTAssertEqual(movingWindow(id(1), to: .swap(id(1)), in: start), start)
        XCTAssertEqual(movingWindow(id(9), to: .swap(id(2)), in: start), start)
        XCTAssertEqual(movingWindow(id(1), to: .newColumn(beside: id(1), after: true), in: start), start)
    }

    // MARK: - Config

    func testConfigDefaultsToOptionForBothDrags() {
        XCTAssertEqual(GioConfig().behavior.mouseDrag, MouseDragSettings(move: true, resize: true, modifiers: [.alt]))
    }

    func testConfigKeys() throws {
        let text = "[behavior]\nmouse-move-window = false\nmouse-resize-window = true\nmouse-drag-modifier = \"Ctrl+Option\"\n"
        let (config, messages) = try parseGioConfig(text).get()
        XCTAssertEqual(messages, [])
        XCTAssertEqual(config.behavior.mouseDrag, MouseDragSettings(move: false, resize: true, modifiers: [.ctrl, .alt]))
    }

    func testAnUnknownModifierKeepsTheDefault() throws {
        for bad in ["\"hyper\"", "\"\"", "3"] {
            let result = parseGioConfig("[behavior]\nmouse-drag-modifier = \(bad)\n")
            switch result {
            case .success(let (config, messages)):
                XCTAssertFalse(messages.isEmpty, bad)
                XCTAssertEqual(config.behavior.mouseDrag.modifiers, [.alt], bad)
            case .failure:
                break
            }
        }
    }
}
