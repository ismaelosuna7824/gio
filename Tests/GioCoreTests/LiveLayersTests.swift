import CoreGraphics
import XCTest
@testable import GioCore

final class LiveLayersTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    private let left = CGRect(x: 0, y: 100, width: 800, height: 900)
    private let right = CGRect(x: 820, y: 100, width: 800, height: 900)
    private let parked = CGRect(x: 1799, y: 100, width: 800, height: 900)
    private let offLeft = CGRect(x: -799, y: 100, width: 800, height: 900)

    private func id(_ value: UInt64) -> WindowID {
        WindowID(pid: 1, elementID: value)
    }

    private func candidates(
        _ moves: [WindowID: (from: CGRect, to: CGRect)], excluded: Set<WindowID> = [], limit: Int = liveLayerMaxStreams
    ) -> [WindowID] {
        liveLayerCandidates(
            ids: Set(moves.keys), excluded: excluded, starts: moves.mapValues(\.from), targets: moves.mapValues(\.to),
            displays: [screen], limit: limit
        )
    }

    func testAMovingWindowVisibleAtItsStartOrTargetIsStreamed() {
        XCTAssertEqual(candidates([id(1): (left, right)]), [id(1)])
        XCTAssertEqual(candidates([id(2): (parked, right)]), [id(2)], "slides in")
        XCTAssertEqual(candidates([id(3): (left, offLeft)]), [id(3)], "slides out")
    }

    func testStillHiddenExcludedAndResizedWindowsAreNotStreamed() {
        let wide = CGRect(x: 0, y: 100, width: 1600, height: 900)
        XCTAssertEqual(candidates([id(1): (left, left)]), [], "keeps its frame: the real window shows")
        XCTAssertEqual(candidates([id(2): (parked, parked.offsetBy(dx: 10, dy: 0))]), [], "never on screen")
        XCTAssertEqual(candidates([id(3): (left, right)], excluded: [id(3)]), [], "see-through or opening")
        XCTAssertEqual(candidates([id(4): (left, wide)]), [], "a resize keeps its SM-30 fresh capture")
    }

    func testWindowsLandingOnScreenComeFirstWithinTheLimit() {
        let leaving = id(1)
        let arriving = id(2)
        let moving = id(3)
        let selection = candidates([leaving: (left, offLeft), arriving: (parked, right), moving: (left, right)], limit: 2)
        XCTAssertEqual(selection, [arriving, moving])
    }

    func testTheLogLinesCarryIdsCountsAndTimingsOnly() {
        XCTAssertEqual(liveLayerStartLine(count: 2), "live layer start count=2")
        XCTAssertEqual(
            liveLayerFirstFrameLine(WindowID(pid: 13261, elementID: 4), milliseconds: 48),
            "live layer first frame id=13261:4 ms=48"
        )
        XCTAssertEqual(liveLayerStopLine(count: 2, frames: 41), "live layer stop count=2 frames=41")
    }
}
