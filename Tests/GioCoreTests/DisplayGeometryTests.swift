import XCTest
@testable import GioCore

/// MM-01: display geometry decisions — the primary display (the global AX
/// flip), position order, the display a window sits on, and the neighbour
/// in a direction (used by the monitor actions).
final class DisplayGeometryTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let left = CGRect(x: -2560, y: -200, width: 2560, height: 1440)
    private let right = CGRect(x: 1512, y: 0, width: 1600, height: 1000)
    private let above = CGRect(x: 200, y: 982, width: 1920, height: 1080)

    // MARK: Primary

    func testThePrimaryDisplayIsTheOneAtTheCocoaOrigin() {
        XCTAssertEqual(primaryDisplayIndex([left, right, laptop]), 2)
        XCTAssertEqual(primaryDisplayIndex([laptop, left]), 0)
    }

    func testWithoutAnOriginDisplayTheFirstOneIsPrimary() {
        XCTAssertEqual(primaryDisplayIndex([right, left]), 0)
        XCTAssertNil(primaryDisplayIndex([]))
    }

    // MARK: Order

    func testDisplaysOrderLeftToRightThenTopToBottom() {
        let frames: [DisplayID: CGRect] = [
            DisplayID(1): laptop, DisplayID(2): right, DisplayID(3): left,
            DisplayID(4): CGRect(x: 0, y: 982, width: 1512, height: 900),
        ]
        XCTAssertEqual(
            displaysByPosition(frames), [DisplayID(3), DisplayID(4), DisplayID(1), DisplayID(2)]
        )
    }

    func testIdenticalPositionsFallBackToTheID() {
        let frames: [DisplayID: CGRect] = [DisplayID(9): laptop, DisplayID(4): laptop]
        XCTAssertEqual(displaysByPosition(frames), [DisplayID(4), DisplayID(9)])
    }

    // MARK: Display for a frame

    func testAWindowBelongsToTheDisplayHoldingMostOfIt() {
        let displays: [DisplayID: CGRect] = [DisplayID(1): laptop, DisplayID(2): right]
        XCTAssertEqual(displayFor(frame: CGRect(x: 100, y: 100, width: 800, height: 600), displays: displays), DisplayID(1))
        XCTAssertEqual(displayFor(frame: CGRect(x: 1700, y: 100, width: 800, height: 600), displays: displays), DisplayID(2))
        // 212 pt on the laptop, 388 pt on the right display.
        XCTAssertEqual(displayFor(frame: CGRect(x: 1300, y: 100, width: 600, height: 600), displays: displays), DisplayID(2))
    }

    func testAWindowOnNoDisplayHasNone() {
        let displays: [DisplayID: CGRect] = [DisplayID(1): laptop]
        XCTAssertNil(displayFor(frame: CGRect(x: 5000, y: 100, width: 800, height: 600), displays: displays))
        XCTAssertNil(displayFor(frame: .zero, displays: displays))
        XCTAssertNil(displayFor(frame: CGRect(x: 100, y: 100, width: 800, height: 600), displays: [:]))
    }

    func testAnEvenSplitGoesToTheFirstDisplayInPositionOrder() {
        let displays: [DisplayID: CGRect] = [DisplayID(2): laptop, DisplayID(1): right]
        XCTAssertEqual(displayFor(frame: CGRect(x: 1312, y: 100, width: 400, height: 600), displays: displays), DisplayID(2))
    }

    // MARK: Neighbour

    private var arrangement: [DisplayID: CGRect] {
        [DisplayID(1): laptop, DisplayID(2): right, DisplayID(3): left, DisplayID(4): above]
    }

    func testNeighboursInEveryDirection() {
        XCTAssertEqual(displayNeighbour(of: DisplayID(1), direction: .right, frames: arrangement), DisplayID(2))
        XCTAssertEqual(displayNeighbour(of: DisplayID(1), direction: .left, frames: arrangement), DisplayID(3))
        XCTAssertEqual(displayNeighbour(of: DisplayID(1), direction: .up, frames: arrangement), DisplayID(4))
        XCTAssertNil(displayNeighbour(of: DisplayID(1), direction: .down, frames: arrangement))
        XCTAssertEqual(displayNeighbour(of: DisplayID(4), direction: .down, frames: arrangement), DisplayID(1))
        XCTAssertNil(displayNeighbour(of: DisplayID(2), direction: .right, frames: arrangement))
    }

    func testAnOverlappingNeighbourBeatsACloserDiagonalOne() {
        // To the right of the laptop: a diagonal display touching its corner
        // and a farther one beside it. The one beside it wins.
        let frames: [DisplayID: CGRect] = [
            DisplayID(1): laptop,
            DisplayID(2): CGRect(x: 1512, y: 982, width: 1000, height: 800),
            DisplayID(3): CGRect(x: 1800, y: 0, width: 1600, height: 900),
        ]
        XCTAssertEqual(displayNeighbour(of: DisplayID(1), direction: .right, frames: frames), DisplayID(3))
    }

    func testWithoutOverlapTheNearestEdgeWinsThenTheNearestCentre() {
        let frames: [DisplayID: CGRect] = [
            DisplayID(1): laptop,
            DisplayID(2): CGRect(x: 1512, y: 1200, width: 1000, height: 800),
            DisplayID(3): CGRect(x: 1512, y: -1100, width: 1000, height: 800),
            DisplayID(4): CGRect(x: 3000, y: 1000, width: 1000, height: 800),
        ]
        // 2 and 3 share the edge distance; 2's centre is nearer.
        XCTAssertEqual(displayNeighbour(of: DisplayID(1), direction: .right, frames: frames), DisplayID(2))
    }

    func testAmongOverlappingNeighboursTheNearestEdgeWins() {
        let frames: [DisplayID: CGRect] = [
            DisplayID(1): laptop,
            DisplayID(2): CGRect(x: 3200, y: 0, width: 1600, height: 1000),
            DisplayID(3): right,
        ]
        XCTAssertEqual(displayNeighbour(of: DisplayID(1), direction: .right, frames: frames), DisplayID(3))
    }

    func testAnUnknownDisplayHasNoNeighbour() {
        XCTAssertNil(displayNeighbour(of: DisplayID(42), direction: .right, frames: arrangement))
        XCTAssertNil(displayNeighbour(of: DisplayID(1), direction: .right, frames: [DisplayID(1): laptop]))
    }
}
