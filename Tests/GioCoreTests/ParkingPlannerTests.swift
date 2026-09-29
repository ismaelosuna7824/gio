import XCTest
@testable import GioCore

/// WC-06: off-viewport columns are parked with 1pt inside the display,
/// keeping their size and y. Cocoa space (y up), same as layout/reconciler.
final class ParkingPlannerTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 1, elementID: element)
    }

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)

    func testVisibleFramesAreUntouched() {
        let frames = [
            id(1): CGRect(x: 8, y: 8, width: 900, height: 984),
            id(2): CGRect(x: 1700, y: 8, width: 600, height: 984), // sliver peeks in
        ]
        let plan = planParking(frames: frames, viewport: display, display: display, otherDisplays: [])
        XCTAssertEqual(plan.visible, frames)
        XCTAssertTrue(plan.parked.isEmpty)
    }

    func testLeftColumnParksAtLeftEdgeKeepingSizeAndY() {
        let frame = CGRect(x: -1000, y: 8, width: 900, height: 984)
        let plan = planParking(frames: [id(1): frame], viewport: display, display: display, otherDisplays: [])
        let target = plan.parked[id(1)]
        XCTAssertEqual(target?.frame, CGRect(x: -899, y: 8, width: 900, height: 984))
        XCTAssertEqual(target?.edge, .left)
        XCTAssertTrue(plan.visible.isEmpty)
    }

    func testRightColumnParksAtRightEdge() {
        let frame = CGRect(x: 2000, y: 8, width: 700, height: 984)
        let plan = planParking(frames: [id(1): frame], viewport: display, display: display, otherDisplays: [])
        XCTAssertEqual(plan.parked[id(1)]?.frame, CGRect(x: 1799, y: 8, width: 700, height: 984))
        XCTAssertEqual(plan.parked[id(1)]?.edge, .right)
    }

    func testEdgeTouchingViewportCountsAsOffViewport() {
        let frame = CGRect(x: 1800, y: 8, width: 500, height: 984)
        let plan = planParking(frames: [id(1): frame], viewport: display, display: display, otherDisplays: [])
        XCTAssertEqual(plan.parked[id(1)]?.edge, .right)
    }

    func testRightNeighbourDisplayFlipsRightColumnToLeftEdge() {
        let neighbour = CGRect(x: 1800, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 2000, y: 8, width: 700, height: 984)
        let plan = planParking(frames: [id(1): frame], viewport: display, display: display, otherDisplays: [neighbour])
        XCTAssertEqual(plan.parked[id(1)]?.frame, CGRect(x: -699, y: 8, width: 700, height: 984))
        XCTAssertEqual(plan.parked[id(1)]?.edge, .left)
    }

    func testLeftNeighbourDisplayFlipsLeftColumnToRightEdge() {
        let neighbour = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: -1000, y: 8, width: 900, height: 984)
        let plan = planParking(frames: [id(1): frame], viewport: display, display: display, otherDisplays: [neighbour])
        XCTAssertEqual(plan.parked[id(1)]?.frame, CGRect(x: 1799, y: 8, width: 900, height: 984))
        XCTAssertEqual(plan.parked[id(1)]?.edge, .right)
    }

    func testBothEdgesSharedFallsBackToBottomRightCorner() {
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1800, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 2000, y: 8, width: 700, height: 984)
        let plan = planParking(frames: [id(1): frame], viewport: display, display: display, otherDisplays: [left, right])
        // Cocoa bottom-right: window hangs below minY with 1pt inside.
        XCTAssertEqual(plan.parked[id(1)]?.frame, CGRect(x: 1799, y: -983, width: 700, height: 984))
        XCTAssertEqual(plan.parked[id(1)]?.edge, .corner)
    }

    func testNeighbourAboveDoesNotBlockSideParkingWhenNotOverlapping() {
        // Parked rect spans y 8..992; a display far above does not overlap it.
        let above = CGRect(x: 0, y: 1000, width: 1800, height: 900)
        let frame = CGRect(x: 2000, y: 8, width: 700, height: 984)
        let plan = planParking(frames: [id(1): frame], viewport: display, display: display, otherDisplays: [above])
        XCTAssertEqual(plan.parked[id(1)]?.edge, .right)
    }

    func testViewportSmallerThanDisplayStillParksAtDisplayEdge() {
        // Dock on the left: visible frame is inset, parking uses the full display.
        let visible = CGRect(x: 80, y: 0, width: 1720, height: 1000)
        let frame = CGRect(x: -900, y: 8, width: 900, height: 984)
        let plan = planParking(frames: [id(1): frame], viewport: visible, display: display, otherDisplays: [])
        XCTAssertEqual(plan.parked[id(1)]?.frame.maxX, 1)
    }
}
