import XCTest
@testable import GioCore

/// DW-01: the dwindle tree (insertion, removal) and `DwindleLayoutEngine`
/// geometry: padding, gaps, orientation by aspect ratio, preselection,
/// ratios and windows that are not tiled.
final class DwindleLayoutEngineTests: XCTestCase {
    /// 1000x600 at the origin, 10 pt padding and gaps: the usable area is
    /// (10, 10, 980, 580).
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let engine = DwindleLayoutEngine(config: LayoutConfig(padding: 10, gap: 10))

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 7, elementID: element)
    }

    /// Windows 1...n inserted in order, each splitting the previous one.
    private func spiral(_ count: UInt64) -> DwindleState {
        var state = DwindleState()
        for n in 1...count {
            state.insert(id(n), ratio: 1)
        }
        return state
    }

    private func frames(_ state: DwindleState, modes: [WindowID: WindowMode] = [:]) throws -> [WindowID: CGRect] {
        try engine.layout(state, viewport: viewport, modes: modes).frames
    }

    // MARK: - Geometry, 1 to 5 windows

    func testOneWindowFillsTheAreaInsideThePadding() throws {
        XCTAssertEqual(try frames(spiral(1)), [id(1): CGRect(x: 10, y: 10, width: 980, height: 580)])
    }

    func testTwoWindowsSitSideBySideOnAWideArea() throws {
        XCTAssertEqual(try frames(spiral(2)), [
            id(1): CGRect(x: 10, y: 10, width: 485, height: 580),
            id(2): CGRect(x: 505, y: 10, width: 485, height: 580),
        ])
    }

    func testTheThirdWindowStacksUnderTheTallHalfItSplits() throws {
        // The right half is 485x580 (taller than wide): window 2 keeps the
        // top (Cocoa: the upper, larger-y part), window 3 takes the bottom.
        XCTAssertEqual(try frames(spiral(3)), [
            id(1): CGRect(x: 10, y: 10, width: 485, height: 580),
            id(2): CGRect(x: 505, y: 305, width: 485, height: 285),
            id(3): CGRect(x: 505, y: 10, width: 485, height: 285),
        ])
    }

    func testFourAndFiveWindowsKeepSpiralling() throws {
        let four = try frames(spiral(4))
        XCTAssertEqual(four[id(3)], CGRect(x: 505, y: 10, width: 238, height: 285))
        XCTAssertEqual(four[id(4)], CGRect(x: 753, y: 10, width: 237, height: 285))
        let five = try frames(spiral(5))
        XCTAssertEqual(five[id(1)], CGRect(x: 10, y: 10, width: 485, height: 580))
        XCTAssertEqual(five[id(2)], CGRect(x: 505, y: 305, width: 485, height: 285))
        XCTAssertEqual(five[id(3)], CGRect(x: 505, y: 10, width: 238, height: 285))
        XCTAssertEqual(five[id(4)], CGRect(x: 753, y: 157, width: 237, height: 138))
        XCTAssertEqual(five[id(5)], CGRect(x: 753, y: 10, width: 237, height: 137))
    }

    // MARK: - BUG-3: learned minimum sizes

    private func frames(_ state: DwindleState, minimums: [WindowID: CGSize]) throws -> [WindowID: CGRect] {
        try DwindleLayoutEngine(config: LayoutConfig(padding: 10, gap: 10), minimumSizes: minimums)
            .layout(state, viewport: viewport).frames
    }

    /// Live 2026-10-21: nine windows in a dwindle tree asked WhatsApp (970)
    /// and Figma (900) for tiles a few hundred points wide; they clamped,
    /// overlapped their neighbours and the passes fought them. A split now
    /// gives each side at least its minimum when the two fit together.
    func testASplitGivesASideItsMinimumWhenBothFit() throws {
        let wide = try frames(spiral(2), minimums: [id(1): CGSize(width: 700, height: 0)])
        XCTAssertEqual(wide[id(1)], CGRect(x: 10, y: 10, width: 700, height: 580))
        XCTAssertEqual(wide[id(2)], CGRect(x: 720, y: 10, width: 270, height: 580))
        let second = try frames(spiral(2), minimums: [id(2): CGSize(width: 700, height: 0)])
        XCTAssertEqual(second[id(1)]?.width, 270)
        XCTAssertEqual(second[id(2)]?.width, 700)
    }

    func testMinimumsThatCannotBothFitShareInProportion() throws {
        let both = try frames(spiral(2), minimums: [
            id(1): CGSize(width: 700, height: 0), id(2): CGSize(width: 600, height: 0),
        ])
        // 970 for both (980 minus the gap): 700:600 of it.
        XCTAssertEqual(both[id(1)]?.width, 522)
        XCTAssertEqual(both[id(2)]?.width, 448)
    }

    func testAStackedSubtreeNeedsItsWidestMinimum() throws {
        // Window 1 on the left, 2 above 3 on the right: 3's 600 pt minimum
        // widens the whole right half.
        let laid = try frames(spiral(3), minimums: [id(3): CGSize(width: 600, height: 0)])
        XCTAssertEqual(laid[id(1)]?.width, 370)
        XCTAssertEqual(laid[id(2)]?.width, 600)
        XCTAssertEqual(laid[id(3)]?.width, 600)
    }

    func testHeightMinimumsMoveAStackedSplit() throws {
        let laid = try frames(spiral(3), minimums: [id(3): CGSize(width: 0, height: 400)])
        XCTAssertEqual(laid[id(3)]?.height, 400)
        XCTAssertEqual(laid[id(2)]?.height, 170)
    }

    func testTilesNeverOverlapAndKeepTheGapBetweenThem() throws {
        for count in UInt64(1)...5 {
            let laid = try frames(spiral(count))
            XCTAssertEqual(laid.count, Int(count))
            let rects = Array(laid.values)
            for (i, a) in rects.enumerated() {
                XCTAssertTrue(viewport.insetBy(dx: 10, dy: 10).contains(a), "\(count): inside the padding")
                for b in rects[(i + 1)...] {
                    XCTAssertFalse(a.insetBy(dx: -4.9, dy: -4.9).intersects(b), "\(count): tiles keep the gap")
                }
            }
        }
    }

    func testZeroGapsAndPaddingTileTheWholeViewport() throws {
        let tight = DwindleLayoutEngine(config: LayoutConfig(padding: 0, gap: 0))
        let laid = try tight.layout(spiral(3), viewport: viewport, modes: [:]).frames
        XCTAssertEqual(laid[id(1)], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(laid[id(2)], CGRect(x: 500, y: 300, width: 500, height: 300))
        XCTAssertEqual(laid[id(3)], CGRect(x: 500, y: 0, width: 500, height: 300))
    }

    func testTheViewportOriginOffsetsEveryFrame() throws {
        let shifted = CGRect(x: 1800, y: -200, width: 1000, height: 600)
        let laid = try engine.layout(spiral(2), viewport: shifted, modes: [:]).frames
        XCTAssertEqual(laid[id(1)], CGRect(x: 1810, y: -190, width: 485, height: 580))
        XCTAssertEqual(laid[id(2)], CGRect(x: 2305, y: -190, width: 485, height: 580))
    }

    // MARK: - Orientation

    func testAPortraitAreaStacksTheFirstSplit() throws {
        let portrait = CGRect(x: 0, y: 0, width: 600, height: 1000)
        let laid = try engine.layout(spiral(2), viewport: portrait, modes: [:]).frames
        XCTAssertEqual(laid[id(1)], CGRect(x: 10, y: 505, width: 580, height: 485))
        XCTAssertEqual(laid[id(2)], CGRect(x: 10, y: 10, width: 580, height: 485))
    }

    func testTheSplitWidthMultiplierBiasesTowardsStacking() throws {
        var config = LayoutConfig(padding: 10, gap: 10)
        config.dwindle.splitWidthMultiplier = 2
        // 980 wide is less than 2 x 580: the first split stacks.
        let laid = try DwindleLayoutEngine(config: config).layout(spiral(2), viewport: viewport, modes: [:])
        XCTAssertEqual(laid.frames[id(1)], CGRect(x: 10, y: 305, width: 980, height: 285))
        XCTAssertEqual(laid.frames[id(2)], CGRect(x: 10, y: 10, width: 980, height: 285))
        XCTAssertEqual(laid.splits[[]]?.orientation, .vertical)
    }

    func testAPinnedOrientationIgnoresTheShape() throws {
        var state = spiral(2)
        state.root = state.root?.mappingSplits { split in
            var pinned = split
            pinned.orientation = .vertical
            return pinned
        }
        let laid = try frames(state)
        XCTAssertEqual(laid[id(1)], CGRect(x: 10, y: 305, width: 980, height: 285))
        XCTAssertEqual(laid[id(2)], CGRect(x: 10, y: 10, width: 980, height: 285))
    }

    // MARK: - Ratio

    func testTheRatioIsTheFirstChildsShareTimesTwo() throws {
        var state = DwindleState()
        state.insert(id(1), ratio: 1.2)
        state.insert(id(2), ratio: 1.2)
        let laid = try frames(state)
        XCTAssertEqual(laid[id(1)]?.width, 582)
        XCTAssertEqual(laid[id(2)], CGRect(x: 602, y: 10, width: 388, height: 580))
    }

    func testRatiosAreClampedToPointOneThroughOnePointNine() {
        XCTAssertEqual(DwindleSplit(ratio: 5, first: .leaf(id(1)), second: .leaf(id(2))).ratio, 1.9)
        XCTAssertEqual(DwindleSplit(ratio: 0, first: .leaf(id(1)), second: .leaf(id(2))).ratio, 0.1)
        XCTAssertEqual(clampedDwindleRatio(.nan), 1)
    }

    // MARK: - Preselection

    func testPreselectingLeftPutsTheNewWindowFirstAndPinsTheSplit() throws {
        var state = spiral(1)
        state.preselection = .left
        state.insert(id(2), ratio: 1)
        XCTAssertNil(state.preselection, "a preselection is used once")
        XCTAssertEqual(state.root, .split(DwindleSplit(
            orientation: .horizontal, first: .leaf(id(2)), second: .leaf(id(1))
        )))
        let laid = try frames(state)
        XCTAssertEqual(laid[id(2)], CGRect(x: 10, y: 10, width: 485, height: 580))
        XCTAssertEqual(laid[id(1)], CGRect(x: 505, y: 10, width: 485, height: 580))
    }

    func testPreselectingUpOrDownStacksEvenOnAWideArea() throws {
        for (direction, top) in [(FocusDirection.up, id(2)), (FocusDirection.down, id(1))] {
            var state = spiral(1)
            state.preselection = direction
            state.insert(id(2), ratio: 1)
            let laid = try frames(state)
            XCTAssertEqual(laid[top], CGRect(x: 10, y: 305, width: 980, height: 285), "\(direction)")
        }
    }

    func testPreselectingRightSplitsTheSelectedLeafSideBySide() throws {
        // Window 3 would stack under window 2; preselecting right keeps it beside.
        var state = spiral(2)
        state.preselection = .right
        state.insert(id(3), ratio: 1)
        let laid = try frames(state)
        XCTAssertEqual(laid[id(2)], CGRect(x: 505, y: 10, width: 238, height: 580))
        XCTAssertEqual(laid[id(3)], CGRect(x: 753, y: 10, width: 237, height: 580))
    }

    // MARK: - Insertion and removal

    func testInsertionSplitsTheSelectedLeaf() {
        var state = spiral(3)
        state.selected = id(1)
        state.insert(id(4), ratio: 1)
        XCTAssertEqual(state.windows, [id(1), id(4), id(2), id(3)])
        XCTAssertEqual(state.selected, id(4), "the new window is selected")
    }

    func testAStaleSelectionSplitsTheLastLeaf() {
        var state = spiral(2)
        state.selected = id(99)
        state.insert(id(3), ratio: 1)
        XCTAssertEqual(state.windows, [id(1), id(2), id(3)])
        XCTAssertEqual(state.root?.path(to: id(3)), [.second, .second])
    }

    func testRemovingAWindowCollapsesItsParentIntoTheSibling() throws {
        var state = spiral(3)
        state.remove(id(2))
        XCTAssertEqual(state.root, .split(DwindleSplit(first: .leaf(id(1)), second: .leaf(id(3)))))
        XCTAssertEqual(state.selected, id(3), "removing another window keeps the selection")
        XCTAssertEqual(try frames(state)[id(3)], CGRect(x: 505, y: 10, width: 485, height: 580))
        state.remove(id(1))
        XCTAssertEqual(state.root, .leaf(id(3)))
        state.remove(id(3))
        XCTAssertNil(state.root)
        XCTAssertEqual(try frames(state), [:])
    }

    func testRemovingTheSelectedOrMaximizedWindowForgetsIt() {
        var state = spiral(2)
        state.maximized = id(2)
        state.remove(id(2))
        XCTAssertNil(state.selected)
        XCTAssertNil(state.maximized)
    }

    func testSwappingLeavesTradesPlaces() {
        let swapped = spiral(3).root?.swappingLeaves(id(1), id(3))
        XCTAssertEqual(swapped?.windows, [id(3), id(2), id(1)])
    }

    // MARK: - Windows that are not tiled

    func testANonTiledLeafGivesItsSpaceToItsSibling() throws {
        let laid = try frames(spiral(3), modes: [id(2): .floating])
        XCTAssertEqual(laid, [
            id(1): CGRect(x: 10, y: 10, width: 485, height: 580),
            id(3): CGRect(x: 505, y: 10, width: 485, height: 580),
        ])
        XCTAssertEqual(try frames(spiral(2), modes: [id(1): .floating]), [
            id(2): CGRect(x: 10, y: 10, width: 980, height: 580),
        ])
        XCTAssertEqual(try frames(spiral(2), modes: [id(1): .floating, id(2): .fullscreen]), [:])
    }

    // MARK: - Invalid input

    func testInvalidViewportsAndConfigurationsThrow() {
        XCTAssertThrowsError(try engine.layout(spiral(1), viewport: .zero, modes: [:]))
        XCTAssertThrowsError(try engine.layout(spiral(1), viewport: CGRect(x: 0, y: 0, width: 10, height: 10), modes: [:]))
        let negative = DwindleLayoutEngine(config: LayoutConfig(padding: -1, gap: 8))
        XCTAssertThrowsError(try negative.layout(spiral(1), viewport: viewport, modes: [:]))
    }

    func testDeepTreesStillEmitPositiveFrames() throws {
        let laid = try DwindleLayoutEngine(config: LayoutConfig(padding: 8, gap: 8))
            .layout(spiral(40), viewport: CGRect(x: 0, y: 0, width: 400, height: 300), modes: [:]).frames
        XCTAssertEqual(laid.count, 40)
        for frame in laid.values {
            XCTAssertGreaterThanOrEqual(frame.width, 1)
            XCTAssertGreaterThanOrEqual(frame.height, 1)
            XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
        }
    }
}
