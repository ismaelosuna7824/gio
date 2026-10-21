import CoreGraphics
import GioCore
import XCTest
@testable import GioUI

/// WO-01: what the overview panel's keys and picks do, without a window.
@MainActor
final class WorkspaceOverviewModelTests: XCTestCase {
    private var events: [String] = []
    private var moves: [OverviewMove] = []

    private func strip(_ index: Int, focused: String?, ids: [String]) -> WorkspaceStripFact {
        WorkspaceStripFact(
            displayID: 1, workspace: index, viewportWidth: 1800, viewportHeight: 1000, viewportOffset: 0,
            contentWidth: CGFloat(ids.count) * 900,
            columns: ids.enumerated().map { offset, id in
                StripColumnFact(
                    x: CGFloat(offset) * 900, width: 900,
                    windows: [StripWindowFact(id: id, application: "App", top: 0, height: 1000)]
                )
            },
            focusedColumn: nil, focusedWindowID: focused
        )
    }

    /// 1 "Code": 1:1, 1:2 (focused); 2: 2:3; 3: empty.
    private func facts1() -> WorkspaceOverviewFacts {
        WorkspaceOverviewFacts(displayID: 1, activeWorkspace: 1, strips: [
            strip(1, focused: "1:2", ids: ["1:1", "1:2"]),
            strip(2, focused: nil, ids: ["2:3"]),
            strip(3, focused: nil, ids: []),
        ])
    }

    private func make(
        alive: Set<String> = ["1:1", "1:2", "2:3"], reply: WorkspaceOverviewFacts? = nil
    ) -> WorkspaceOverviewModel {
        let facts = facts1()
        let model = WorkspaceOverviewModel(
            facts: facts,
            stack: [WorkspaceEntry(index: 1, windows: 2, columns: 2, isActive: true, name: "Code")],
            titles: ["1:2": "notes.md"],
            focusWindow: { [unowned self] id in
                events.append("window \(id)")
                return alive.contains(id)
            },
            focusWorkspace: { [unowned self] index in events.append("workspace \(index)") },
            move: { [unowned self] move, done in
                moves.append(move)
                done(reply)
            }
        )
        model.dismiss = { [unowned self] reason in events.append("dismiss \(reason.rawValue)") }
        return model
    }

    func testRowsCarryNamesTitlesAndTheActiveWorkspace() {
        let model = make()
        XCTAssertEqual(model.rows.map(\.title), ["1 · Code", "Workspace 2", "Workspace 3"])
        XCTAssertEqual(model.rows.map(\.isActive), [true, false, false])
        XCTAssertEqual(model.rows.map(\.miniature.tiles.count), [2, 1, 0])
        XCTAssertEqual(model.title(of: "1:2"), "notes.md")
        XCTAssertEqual(model.windowIDs, ["1:1", "1:2", "2:3"])
    }

    func testEscapeClosesWithoutGoingAnywhere() {
        let model = make()
        XCTAssertTrue(model.handle(.escape))
        XCTAssertEqual(events, ["dismiss escape"])
    }

    func testReturnClosesThenFocusesTheSelectedWindow() {
        let model = make()
        XCTAssertEqual(model.selection, OverviewSelection(workspace: 1, windowID: "1:2"))
        XCTAssertTrue(model.handle(.step(.left)))
        XCTAssertTrue(model.handle(.enter))
        XCTAssertEqual(events, ["dismiss pick", "window 1:1"])
    }

    func testReturnOnAnEmptyWorkspaceGoesThere() {
        let model = make()
        model.handle(.step(.down))
        model.handle(.step(.down))
        XCTAssertEqual(model.selection, OverviewSelection(workspace: 3, windowID: nil))
        model.handle(.enter)
        XCTAssertEqual(events, ["dismiss pick", "workspace 3"])
    }

    func testAWindowThatVanishedFallsBackToItsWorkspace() {
        let model = make(alive: [])
        model.pick(OverviewSelection(workspace: 2, windowID: "2:3"))
        XCTAssertEqual(events, ["dismiss pick", "window 2:3", "workspace 2"])
    }

    func testDigitsGoToAWorkspaceOfTheStackOnly() {
        let model = make()
        XCTAssertTrue(model.handle(.digit(2)))
        XCTAssertEqual(events, ["dismiss pick", "workspace 2"])
        events = []
        XCTAssertFalse(make().handle(.digit(7)), "past the stack the key is not ours")
        XCTAssertEqual(events, [])
    }

    func testRowHeightFitsTheStackWithinItsBounds() {
        XCTAssertEqual(overviewRowHeight(rows: 3, available: 920, spacing: 10, minimum: 120, maximum: 360), 300)
        XCTAssertEqual(overviewRowHeight(rows: 1, available: 920, spacing: 10, minimum: 120, maximum: 360), 360)
        XCTAssertEqual(overviewRowHeight(rows: 12, available: 920, spacing: 10, minimum: 120, maximum: 360), 120)
        XCTAssertEqual(overviewRowHeight(rows: 0, available: 920, spacing: 10, minimum: 120, maximum: 360), 360)
    }

    func testCanvasKeepsTheStripAspectWithinRowAndWidth() {
        XCTAssertEqual(overviewCanvasSize(aspectRatio: 2, height: 200, maxWidth: 1000), CGSize(width: 400, height: 200))
        XCTAssertEqual(overviewCanvasSize(aspectRatio: 4, height: 200, maxWidth: 400), CGSize(width: 400, height: 100))
    }

    /// The panel's first layout pass can measure zero: SwiftUI rejects a
    /// negative frame ("Invalid frame dimension"), so the canvas is empty.
    func testCanvasIsEmptyNotNegativeBeforeThePanelHasASize() {
        XCTAssertEqual(overviewCanvasSize(aspectRatio: 2, height: 200, maxWidth: -260), .zero)
        XCTAssertEqual(overviewCanvasSize(aspectRatio: 2, height: -40, maxWidth: 1000), .zero)
        XCTAssertEqual(overviewCanvasSize(aspectRatio: .nan, height: 200, maxWidth: 1000).height, 200)
    }

    // MARK: - Thumbnails

    private func image() -> OverviewThumbnail {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return OverviewThumbnail(image: context.makeImage()!)
    }

    func testThumbnailBatchesMergeAndTheLaterOneWins() {
        let model = make()
        let cached = image(), other = image(), fresh = image()
        model.setThumbnails(["1:1": cached])
        model.setThumbnails(["2:3": other])
        XCTAssertEqual(Set(model.thumbnails.keys), ["1:1", "2:3"], "a second batch keeps the first")
        model.setThumbnails(["1:1": fresh])
        XCTAssertTrue(model.thumbnails["1:1"]?.image === fresh.image)
        XCTAssertTrue(model.thumbnails["2:3"]?.image === other.image)
    }

    // MARK: - Moving a window

    /// 1:1 moved to workspace 2 after 2:3.
    private func movedFacts() -> WorkspaceOverviewFacts {
        WorkspaceOverviewFacts(displayID: 1, activeWorkspace: 1, strips: [
            strip(1, focused: "1:2", ids: ["1:2"]),
            strip(2, focused: nil, ids: ["2:3", "1:1"]),
            strip(3, focused: nil, ids: []),
        ])
    }

    func testAMoveRefreshesTheRowsKeepsThumbnailsAndSelectsTheMovedWindow() {
        let model = make(reply: movedFacts())
        let thumb = image()
        model.setThumbnails(["1:1": thumb, "2:3": image()])
        model.move(OverviewMove(windowID: "1:1", workspace: 2, column: 1))
        XCTAssertEqual(moves, [OverviewMove(windowID: "1:1", workspace: 2, column: 1)])
        XCTAssertEqual(model.rows.map { $0.miniature.tiles.map(\.id) }, [["1:2"], ["2:3", "1:1"], []])
        XCTAssertEqual(model.windowIDs, ["1:2", "2:3", "1:1"])
        XCTAssertEqual(model.rows.map(\.title), ["1 · Code", "Workspace 2", "Workspace 3"])
        XCTAssertTrue(model.thumbnails["1:1"]?.image === thumb.image)
        XCTAssertEqual(model.thumbnails.count, 2)
        XCTAssertEqual(model.selection, OverviewSelection(workspace: 2, windowID: "1:1"))
        XCTAssertNil(model.liftedWindowID)
        XCTAssertEqual(events, [], "the panel stays open")
    }

    func testAMoveWithoutFreshFactsKeepsTheRows() {
        let model = make(reply: nil)
        let before = model.rows
        model.move(OverviewMove(windowID: "1:1", workspace: 2, column: 1))
        XCTAssertEqual(model.rows, before)
        XCTAssertEqual(model.facts, facts1())
        XCTAssertNil(model.liftedWindowID)
    }

    // MARK: - Dragging

    /// Row 1 at y 0..100 (1:1 at x 0..100, 1:2 at 100..200), row 2 at
    /// 100..200 (2:3 at 0..100), row 3 at 200..300 (empty).
    private func dropRows() -> [OverviewDropRow] {
        func tile(_ id: String, _ column: Int, _ y: CGFloat) -> OverviewDropTile {
            OverviewDropTile(windowID: id, column: column, rect: CGRect(x: CGFloat(column) * 100, y: y, width: 100, height: 100))
        }
        return [
            OverviewDropRow(
                workspace: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 100),
                canvas: CGRect(x: 0, y: 0, width: 400, height: 100), tiles: [tile("1:1", 0, 0), tile("1:2", 1, 0)]
            ),
            OverviewDropRow(
                workspace: 2, frame: CGRect(x: 0, y: 100, width: 1000, height: 100),
                canvas: CGRect(x: 0, y: 100, width: 400, height: 100), tiles: [tile("2:3", 0, 100)]
            ),
            OverviewDropRow(
                workspace: 3, frame: CGRect(x: 0, y: 200, width: 1000, height: 100),
                canvas: CGRect(x: 0, y: 200, width: 400, height: 100), tiles: []
            ),
        ]
    }

    func testDroppingATileMovesItThere() {
        let model = make(reply: movedFacts())
        model.drag.rows = dropRows()
        let start = CGPoint(x: 50, y: 50)
        model.dragChanged("1:1", workspace: 1, start: start, location: CGPoint(x: 60, y: 120))
        XCTAssertEqual(model.liftedWindowID, "1:1")
        XCTAssertEqual(model.drag.grab, CGSize(width: 50, height: 50))
        XCTAssertEqual(model.drag.target, OverviewMove(windowID: "1:1", workspace: 2, column: 1))
        model.hover(OverviewSelection(workspace: 2, windowID: "2:3"))
        XCTAssertEqual(model.selection, OverviewSelection(workspace: 1, windowID: "1:1"), "no hover while dragging")
        model.dragEnded("1:1", start: start, location: CGPoint(x: 60, y: 120))
        XCTAssertEqual(moves, [OverviewMove(windowID: "1:1", workspace: 2, column: 1)])
        XCTAssertEqual(model.selection, OverviewSelection(workspace: 2, windowID: "1:1"))
        XCTAssertNil(model.drag.location)
        XCTAssertNil(model.liftedWindowID)
    }

    func testReleasingOutsideEveryRowCancels() {
        let model = make(reply: movedFacts())
        model.drag.rows = dropRows()
        let start = CGPoint(x: 50, y: 50)
        model.dragChanged("1:1", workspace: 1, start: start, location: CGPoint(x: 60, y: 400))
        XCTAssertNil(model.drag.target)
        model.dragEnded("1:1", start: start, location: CGPoint(x: 60, y: 400))
        XCTAssertEqual(moves, [])
        XCTAssertNil(model.liftedWindowID)
        XCTAssertNil(model.drag.location)
    }

    func testEscapeDuringADragCancelsItAndKeepsThePanel() {
        let model = make(reply: movedFacts())
        model.drag.rows = dropRows()
        let start = CGPoint(x: 50, y: 50)
        model.dragChanged("1:1", workspace: 1, start: start, location: CGPoint(x: 60, y: 120))
        XCTAssertTrue(model.handle(.escape))
        XCTAssertEqual(events, [], "escape ends the drag, not the overview")
        XCTAssertNil(model.liftedWindowID)
        XCTAssertNil(model.drag.location)
        model.dragChanged("1:1", workspace: 1, start: start, location: CGPoint(x: 70, y: 130))
        XCTAssertNil(model.liftedWindowID, "the cancelled gesture stays cancelled")
        model.dragEnded("1:1", start: start, location: CGPoint(x: 70, y: 130))
        XCTAssertEqual(moves, [])
        model.dragChanged("1:2", workspace: 1, start: CGPoint(x: 150, y: 50), location: CGPoint(x: 150, y: 250))
        XCTAssertEqual(model.liftedWindowID, "1:2", "the next gesture drags again")
        model.handle(.escape)
        model.handle(.escape)
        XCTAssertEqual(events, ["dismiss escape"])
    }
}
