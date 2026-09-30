import CoreGraphics
import XCTest
@testable import GioCore

/// DD-02: the Overview's live workspace strip — facts built from a layout,
/// the normalized miniature, window grouping and counts.
final class WorkspaceMiniatureTests: XCTestCase {
    private func win(_ pid: Int32) -> WindowID {
        WindowID(pid: pid, elementID: 1)
    }

    private func strip(
        columns: [StripColumnFact], offset: CGFloat = 0, viewportWidth: CGFloat = 1000,
        focusedColumn: Int? = 0, focusedWindow: String? = nil
    ) -> WorkspaceStripFact {
        let content = (columns.map { $0.x + $0.width }.max() ?? 0) + 10
        return WorkspaceStripFact(
            displayID: 1, workspace: 1, viewportWidth: viewportWidth, viewportHeight: 500,
            viewportOffset: offset, contentWidth: content, columns: columns,
            focusedColumn: focusedColumn, focusedWindowID: focusedWindow
        )
    }

    private func column(_ x: CGFloat, _ width: CGFloat, _ ids: [String]) -> StripColumnFact {
        let height = (480 - CGFloat(ids.count - 1) * 10) / CGFloat(ids.count)
        return StripColumnFact(x: x, width: width, windows: ids.enumerated().map { index, id in
            StripWindowFact(id: id, application: "App \(id)", top: 10 + CGFloat(index) * (height + 10), height: height)
        })
    }

    // MARK: - Facts from a layout

    func testStripFactUsesContentCoordinatesAndFocusedWindowColumn() throws {
        let workspace = Workspace(
            id: WorkspaceID(1),
            columns: [
                Column(id: ColumnID(1), width: 400, windows: [win(1)]),
                Column(id: ColumnID(2), width: 600, windows: [win(2), win(3)], focusedWindowIndex: 1),
            ],
            focusedColumn: 0, focusedWindow: win(3), viewportOffset: 200
        )
        let viewport = CGRect(x: 100, y: 50, width: 800, height: 500)
        let layout = try ScrollableLayoutEngine(config: LayoutConfig(padding: 10, gap: 10))
            .calculate(workspace: workspace, viewport: viewport)
        let fact = makeWorkspaceStrip(
            workspace: workspace, layout: layout, viewport: viewport, displayID: 7, index: 2,
            application: { "pid\($0.pid)" }
        )
        XCTAssertEqual(fact.displayID, 7)
        XCTAssertEqual(fact.workspace, 2)
        XCTAssertEqual(fact.viewportOffset, layout.viewportOffset)
        XCTAssertEqual(fact.contentWidth, 1030)
        XCTAssertEqual(fact.columns.map(\.x), [10, 420])
        XCTAssertEqual(fact.columns.map(\.width), [400, 600])
        XCTAssertEqual(fact.columns[1].windows.map(\.application), ["pid2", "pid3"])
        XCTAssertEqual(fact.columns[1].windows[0].top, 10)
        XCTAssertLessThan(fact.columns[1].windows[0].top, fact.columns[1].windows[1].top)
        XCTAssertEqual(fact.focusedColumn, 1, "the focused window's column wins over the stale index")
        XCTAssertEqual(fact.focusedWindowID, "3:1")
    }

    func testStripFactForEmptyWorkspace() throws {
        let workspace = Workspace(id: WorkspaceID(1))
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 500)
        let layout = try ScrollableLayoutEngine().calculate(workspace: workspace, viewport: viewport)
        let fact = makeWorkspaceStrip(
            workspace: workspace, layout: layout, viewport: viewport, displayID: 1, index: 1,
            application: { _ in "" }
        )
        XCTAssertTrue(fact.columns.isEmpty)
        XCTAssertNil(fact.focusedColumn)
        XCTAssertNil(fact.focusedWindowID)
    }

    // MARK: - Miniature

    func testWidthsAreNormalizedToTheStripSpan() {
        let mini = workspaceMiniature(strip(columns: [column(10, 490, ["a"]), column(510, 990, ["b"])]))
        // span = content (1510) since it is wider than the viewport
        XCTAssertEqual(mini.tiles.map(\.rect.minX), [10.0 / 1510, 510.0 / 1510].map { CGFloat($0) })
        XCTAssertEqual(mini.tiles[1].rect.width, 990.0 / 1510, accuracy: 1e-9)
        XCTAssertEqual(mini.aspectRatio, 1510.0 / 500, accuracy: 1e-9)
        XCTAssertEqual(mini.viewport, CGRect(x: 0, y: 0, width: 1000.0 / 1510, height: 1))
    }

    func testNarrowStripSpansTheViewport() {
        let mini = workspaceMiniature(strip(columns: [column(10, 300, ["a"])]))
        XCTAssertEqual(mini.viewport.width, 1)
        XCTAssertEqual(mini.tiles[0].rect.width, 0.3, accuracy: 1e-9)
    }

    func testFocusedAndParkedFlags() {
        let mini = workspaceMiniature(strip(
            columns: [column(10, 490, ["a"]), column(510, 490, ["b", "c"]), column(1010, 490, ["d"]), column(1510, 490, ["e"])],
            offset: 500, focusedColumn: 1, focusedWindow: "c"
        ))
        let byID = Dictionary(uniqueKeysWithValues: mini.tiles.map { ($0.id, $0) })
        XCTAssertTrue(byID["a"]!.isParked, "left of the viewport")
        XCTAssertFalse(byID["b"]!.isParked)
        XCTAssertFalse(byID["d"]!.isParked, "partially visible columns stay")
        XCTAssertTrue(byID["e"]!.isParked, "right of the viewport")
        XCTAssertTrue(byID["b"]!.isFocusedColumn)
        XCTAssertTrue(byID["c"]!.isFocusedColumn)
        XCTAssertFalse(byID["b"]!.isFocusedWindow)
        XCTAssertTrue(byID["c"]!.isFocusedWindow)
        XCTAssertFalse(byID["d"]!.isFocusedColumn)
        XCTAssertEqual(mini.viewport.minX, 500.0 / 2010, accuracy: 1e-9)
    }

    func testStackedWindowsShareTheColumnVertically() {
        let mini = workspaceMiniature(strip(columns: [column(10, 490, ["a", "b", "c"])]))
        let rects = mini.tiles.map(\.rect)
        XCTAssertEqual(Set(rects.map(\.minX)).count, 1)
        XCTAssertEqual(rects[0].minY, 10.0 / 500, accuracy: 1e-9)
        XCTAssertLessThan(rects[0].maxY, rects[1].minY)
        XCTAssertLessThan(rects[1].maxY, rects[2].minY)
        XCTAssertEqual(mini.tiles.map(\.column), [0, 0, 0])
    }

    func testEmptyStripHasOnlyTheViewport() {
        let mini = workspaceMiniature(strip(columns: [], focusedColumn: nil))
        XCTAssertTrue(mini.tiles.isEmpty)
        XCTAssertEqual(mini.viewport, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - Initials, grouping, counts

    func testAppInitials() {
        XCTAssertEqual(appInitials("Safari"), "S")
        XCTAssertEqual(appInitials("Google Chrome"), "GC")
        XCTAssertEqual(appInitials("visual studio code"), "VS")
        XCTAssertEqual(appInitials("  "), "?")
    }

    private func row(_ app: String, _ workspace: Int?, _ state: WindowState = .tiled) -> WindowRow {
        windowRows([WindowFact(
            id: "\(app)\(workspace ?? 0)", application: app, title: "t", workspace: workspace,
            mode: state == .tiled ? .tiled : .floating, floatReason: nil,
            isMinimized: state == .minimized, workspaceIsShown: state != .hidden
        )])[0]
    }

    func testWindowGroupsByWorkspaceWithUnassignedLast() {
        let rows = windowRows([
            WindowFact(id: "1", application: "Notes", title: "a", workspace: nil, mode: .floating, floatReason: .dialog, isMinimized: false, workspaceIsShown: true),
            WindowFact(id: "2", application: "Safari", title: "b", workspace: 2, mode: .tiled, floatReason: nil, isMinimized: false, workspaceIsShown: true),
            WindowFact(id: "3", application: "Mail", title: "c", workspace: 1, mode: .tiled, floatReason: nil, isMinimized: false, workspaceIsShown: false),
            WindowFact(id: "4", application: "Arc", title: "d", workspace: 2, mode: .tiled, floatReason: nil, isMinimized: false, workspaceIsShown: true),
        ])
        let groups = groupWindowRows(rows, activeWorkspace: 2)
        XCTAssertEqual(groups.map(\.title), ["Workspace 1", "Workspace 2", "Other windows"])
        XCTAssertEqual(groups.map(\.isActive), [false, true, false])
        XCTAssertEqual(groups[1].rows.map(\.application), ["Arc", "Safari"])
        XCTAssertEqual(groups[2].rows.map(\.id), ["1"])
    }

    func testWindowCounts() {
        let counts = windowCounts([
            row("A", 1), row("B", 1), row("C", 1, .floating(nil)), row("D", 2, .hidden), row("E", 1, .minimized),
        ])
        XCTAssertEqual(counts, WindowCounts(total: 5, tiled: 2, floating: 1, fullscreen: 0, minimized: 1, hidden: 1))
        XCTAssertEqual(counts.detail, "2 tiled · 1 floating · 1 minimized · 1 hidden")
        XCTAssertEqual(windowCounts([]).detail, "None managed")
    }
}
