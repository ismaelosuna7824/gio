import CoreGraphics
import XCTest
@testable import GioCore

/// WO-01: keyboard selection over the workspace overview's rows.
final class WorkspaceOverviewTests: XCTestCase {
    private func window(_ id: String, top: CGFloat = 0, height: CGFloat = 1000) -> StripWindowFact {
        StripWindowFact(id: id, application: "App", top: top, height: height)
    }

    private func strip(
        _ index: Int, offset: CGFloat = 0, focused: String? = nil, columns: [StripColumnFact]
    ) -> WorkspaceStripFact {
        WorkspaceStripFact(
            displayID: 1, workspace: index, viewportWidth: 1800, viewportHeight: 1000,
            viewportOffset: offset, contentWidth: columns.map { $0.x + $0.width }.max() ?? 0,
            columns: columns, focusedColumn: nil, focusedWindowID: focused
        )
    }

    /// Row 1: [a] [b over c] [d]; row 2 scrolled by 900: [e] [f] [g]; row 3 empty.
    private var facts: WorkspaceOverviewFacts {
        WorkspaceOverviewFacts(displayID: 1, activeWorkspace: 1, strips: [
            strip(1, focused: "b", columns: [
                StripColumnFact(x: 0, width: 600, windows: [window("a")]),
                StripColumnFact(x: 600, width: 600, windows: [
                    window("b", top: 0, height: 500), window("c", top: 500, height: 500),
                ]),
                StripColumnFact(x: 1200, width: 600, windows: [window("d")]),
            ]),
            strip(2, offset: 900, focused: "g", columns: [
                StripColumnFact(x: 0, width: 900, windows: [window("e")]),
                StripColumnFact(x: 900, width: 900, windows: [window("f")]),
                StripColumnFact(x: 1800, width: 900, windows: [window("g")]),
            ]),
            strip(3, columns: []),
        ])
    }

    func testOpensOnTheActiveWorkspacesFocusedWindow() {
        XCTAssertEqual(facts.initialSelection, OverviewSelection(workspace: 1, windowID: "b"))
    }

    func testFallsBackToTheFirstWindowThenToTheBareWorkspace() {
        let unfocused = WorkspaceOverviewFacts(displayID: 1, activeWorkspace: 2, strips: [
            strip(1, columns: []),
            strip(2, columns: [StripColumnFact(x: 0, width: 600, windows: [window("x")])]),
        ])
        XCTAssertEqual(unfocused.initialSelection, OverviewSelection(workspace: 2, windowID: "x"))
        let empty = WorkspaceOverviewFacts(displayID: 1, activeWorkspace: 1, strips: [strip(1, columns: [])])
        XCTAssertEqual(empty.initialSelection, OverviewSelection(workspace: 1, windowID: nil))
    }

    func testLeftAndRightWalkReadingOrderAndStopAtTheEnds() {
        XCTAssertEqual(overviewWindowOrder(facts.strips[0]), ["a", "b", "c", "d"])
        var selection = OverviewSelection(workspace: 1, windowID: "a")
        XCTAssertEqual(facts.selection(selection, stepping: .left), selection)
        for expected in ["b", "c", "d", "d"] {
            selection = facts.selection(selection, stepping: .right)
            XCTAssertEqual(selection, OverviewSelection(workspace: 1, windowID: expected))
        }
    }

    func testUpAndDownLandUnderTheSameVisiblePlace() {
        // `d` is visible at x 1200..1800; row 2 shows `f` at 0..900 and `g` at 900..1800.
        let fromD = facts.selection(OverviewSelection(workspace: 1, windowID: "d"), stepping: .down)
        XCTAssertEqual(fromD, OverviewSelection(workspace: 2, windowID: "g"))
        // `e` is scrolled out on the left (-900..0): nearest in row 1 is `a`.
        let fromE = facts.selection(OverviewSelection(workspace: 2, windowID: "e"), stepping: .up)
        XCTAssertEqual(fromE, OverviewSelection(workspace: 1, windowID: "a"))
        // Inside a stacked column the vertical position decides.
        let stacked = WorkspaceOverviewFacts(displayID: 1, activeWorkspace: 1, strips: [
            strip(1, columns: [StripColumnFact(x: 0, width: 900, windows: [
                window("top", top: 0, height: 500), window("bottom", top: 500, height: 500),
            ])]),
            strip(2, columns: [StripColumnFact(x: 0, width: 900, windows: [window("low", top: 600, height: 400)])]),
        ])
        XCTAssertEqual(
            stacked.selection(OverviewSelection(workspace: 2, windowID: "low"), stepping: .up),
            OverviewSelection(workspace: 1, windowID: "bottom")
        )
    }

    func testAnEmptyWorkspaceIsSelectableAndLeavingItUsesTheFocusedWindow() {
        let empty = facts.selection(OverviewSelection(workspace: 2, windowID: "e"), stepping: .down)
        XCTAssertEqual(empty, OverviewSelection(workspace: 3, windowID: nil))
        XCTAssertEqual(facts.selection(empty, stepping: .right), empty)
        XCTAssertEqual(facts.selection(empty, stepping: .up), OverviewSelection(workspace: 2, windowID: "g"))
    }

    func testTheStackEndsStopVerticalSteps() {
        let top = OverviewSelection(workspace: 1, windowID: "a")
        XCTAssertEqual(facts.selection(top, stepping: .up), top)
        let bottom = OverviewSelection(workspace: 3, windowID: nil)
        XCTAssertEqual(facts.selection(bottom, stepping: .down), bottom)
    }

    func testAWorkspaceRowSelectsItsFocusedWindow() {
        XCTAssertEqual(facts.selection(onWorkspace: 2), OverviewSelection(workspace: 2, windowID: "g"))
        XCTAssertEqual(facts.selection(onWorkspace: 3), OverviewSelection(workspace: 3, windowID: nil))
        XCTAssertNil(facts.selection(onWorkspace: 4))
    }
}
