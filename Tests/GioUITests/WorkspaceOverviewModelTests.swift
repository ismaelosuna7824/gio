import CoreGraphics
import GioCore
import XCTest
@testable import GioUI

/// WO-01: what the overview panel's keys and picks do, without a window.
@MainActor
final class WorkspaceOverviewModelTests: XCTestCase {
    private var events: [String] = []

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
    private func make(alive: Set<String> = ["1:1", "1:2", "2:3"]) -> WorkspaceOverviewModel {
        let facts = WorkspaceOverviewFacts(displayID: 1, activeWorkspace: 1, strips: [
            strip(1, focused: "1:2", ids: ["1:1", "1:2"]),
            strip(2, focused: nil, ids: ["2:3"]),
            strip(3, focused: nil, ids: []),
        ])
        let model = WorkspaceOverviewModel(
            facts: facts,
            stack: [WorkspaceEntry(index: 1, windows: 2, columns: 2, isActive: true, name: "Code")],
            titles: ["1:2": "notes.md"],
            focusWindow: { [unowned self] id in
                events.append("window \(id)")
                return alive.contains(id)
            },
            focusWorkspace: { [unowned self] index in events.append("workspace \(index)") }
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
}
