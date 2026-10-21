import CoreGraphics
import GioCore
import XCTest
@testable import GioUI

/// Where a dragged overview tile lands: the row under the pointer and the
/// column gap left of the first column whose middle is right of it.
final class OverviewDropTargetTests: XCTestCase {
    /// Workspace 4 (y 0..100): column 0 at x 100..200, column 1 stacked
    /// (two tiles at x 210..310), column 2 at 320..420. Workspace 5
    /// (y 100..200): empty.
    private let rows = [
        OverviewDropRow(
            workspace: 4, frame: CGRect(x: 0, y: 0, width: 1000, height: 100),
            canvas: CGRect(x: 100, y: 0, width: 320, height: 100),
            tiles: [
                OverviewDropTile(windowID: "1:1", column: 0, rect: CGRect(x: 100, y: 0, width: 100, height: 100)),
                OverviewDropTile(windowID: "1:2", column: 1, rect: CGRect(x: 210, y: 0, width: 100, height: 50)),
                OverviewDropTile(windowID: "1:3", column: 1, rect: CGRect(x: 210, y: 50, width: 100, height: 50)),
                OverviewDropTile(windowID: "1:4", column: 2, rect: CGRect(x: 320, y: 0, width: 100, height: 100)),
            ]
        ),
        OverviewDropRow(
            workspace: 5, frame: CGRect(x: 0, y: 100, width: 1000, height: 100),
            canvas: CGRect(x: 100, y: 100, width: 320, height: 100), tiles: []
        ),
    ]

    private func target(_ x: CGFloat, _ y: CGFloat) -> OverviewMove? {
        overviewDropTarget(windowID: "9:9", at: CGPoint(x: x, y: y), rows: rows)
    }

    func testLeftOfTheFirstMiddleIsBeforeTheFirstColumn() {
        XCTAssertEqual(target(20, 50), OverviewMove(windowID: "9:9", workspace: 4, column: 0))
        XCTAssertEqual(target(149, 50), OverviewMove(windowID: "9:9", workspace: 4, column: 0))
    }

    func testBetweenMiddlesIsBetweenThoseColumns() {
        XCTAssertEqual(target(151, 50), OverviewMove(windowID: "9:9", workspace: 4, column: 1))
        XCTAssertEqual(target(300, 80), OverviewMove(windowID: "9:9", workspace: 4, column: 2))
    }

    func testAStackedColumnCountsOnce() {
        XCTAssertEqual(target(360, 20), OverviewMove(windowID: "9:9", workspace: 4, column: 2))
    }

    func testRightOfTheLastMiddleIsAfterTheLastColumn() {
        XCTAssertEqual(target(371, 50), OverviewMove(windowID: "9:9", workspace: 4, column: 3))
        XCTAssertEqual(target(990, 50), OverviewMove(windowID: "9:9", workspace: 4, column: 3))
    }

    func testAnEmptyRowTakesColumnZero() {
        XCTAssertEqual(target(600, 150), OverviewMove(windowID: "9:9", workspace: 5, column: 0))
    }

    func testOutsideEveryRowIsNoTarget() {
        XCTAssertNil(target(300, 250))
        XCTAssertNil(target(300, -5))
        XCTAssertNil(target(1200, 50))
    }

    func testTheInsertionBarSitsInTheGap() {
        let bar = { (column: Int) in
            overviewInsertionBar(
                OverviewMove(windowID: "9:9", workspace: 4, column: column), in: self.rows[0], width: 4
            )
        }
        XCTAssertEqual(bar(0), CGRect(x: 95, y: 0, width: 4, height: 100))
        XCTAssertEqual(bar(1), CGRect(x: 203, y: 0, width: 4, height: 100))
        XCTAssertEqual(bar(3), CGRect(x: 421, y: 0, width: 4, height: 100))
        XCTAssertNil(overviewInsertionBar(OverviewMove(windowID: "9:9", workspace: 5, column: 0), in: rows[1], width: 4))
    }
}
