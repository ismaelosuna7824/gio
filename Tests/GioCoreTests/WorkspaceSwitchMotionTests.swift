import XCTest
@testable import GioCore

/// NC-07: workspace switches slide vertically past the bottom edge. Outgoing
/// windows drop below it, incoming ones rise from just below their own frame;
/// nothing sweeps diagonally and a retarget starts from where the window is.
final class WorkspaceSwitchMotionTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private func column(_ x: CGFloat, width: CGFloat = 800) -> CGRect {
        CGRect(x: x, y: 8, width: width, height: 984)
    }

    private func hiddenTargetFor(_ frame: CGRect) -> ParkedTarget {
        hiddenTarget(for: frame, display: display, otherDisplays: [])
    }

    private func plan(
        current: [WindowID: CGRect], visible: [WindowID: CGRect] = [:],
        parked: [WindowID: ParkedTarget] = [:], hidden: [WindowID: ParkedTarget] = [:],
        otherDisplays: [CGRect] = []
    ) -> WorkspaceSwitchMotion {
        planWorkspaceSwitchMotion(
            current: current, visible: visible, parked: parked, hidden: hidden,
            viewport: display, display: display, otherDisplays: otherDisplays, duration: 0.25
        )
    }

    // MARK: MM-03 a display below

    /// A display stacked under `display`, overlapping its x range.
    private let below = CGRect(x: 0, y: -1169, width: 1600, height: 1169)

    func testTheBandBelowIsBlockedOnlyByADisplayThere() {
        XCTAssertTrue(canSlideBelow(display, otherDisplays: []))
        XCTAssertFalse(canSlideBelow(display, otherDisplays: [below]))
        // A side neighbour that only touches the display's edge, even one
        // reaching further down, leaves the band free.
        XCTAssertTrue(canSlideBelow(display, otherDisplays: [CGRect(x: 1800, y: -600, width: 1600, height: 1600)]))
    }

    func testOutgoingWindowDoesNotDropOntoADisplayBelow() {
        let out = id(1)
        let result = plan(
            current: [out: column(100)], hidden: [out: hiddenTargetFor(column(100))], otherDisplays: [below]
        )
        XCTAssertTrue(result.animations.isEmpty, "it jumps at the final pass")
        XCTAssertTrue(result.prepositions.isEmpty)
    }

    func testIncomingWindowFromBelowSnapsWhenADisplayIsBelow() {
        let incoming = id(2)
        let corner = hiddenTargetFor(column(0))
        let result = plan(
            current: [incoming: corner.frame], visible: [incoming: column(500)], otherDisplays: [below]
        )
        XCTAssertTrue(result.prepositions.isEmpty, "no riser is written onto the display below")
        XCTAssertTrue(result.animations.isEmpty, "no diagonal flight across the display below either")
    }

    func testADisplayBelowLeavesScrollingAndSideEntriesAlone() throws {
        let entering = id(3)
        let result = plan(
            current: [entering: CGRect(x: 1799, y: 8, width: 800, height: 984)],
            visible: [entering: column(900)], otherDisplays: [below]
        )
        let animation = try XCTUnwrap(result.animations.first { $0.id == entering })
        XCTAssertEqual(animation.to, column(900))
        XCTAssertTrue(result.prepositions.isEmpty)
    }

    func testSlideDownFrameKeepsXAndSizeAndDropsBelowTheBottomEdge() {
        let below = slideDownFrame(column(300), display: display)
        XCTAssertEqual(below.minX, 300)
        XCTAssertEqual(below.size, column(300).size)
        XCTAssertEqual(below.maxY, display.minY + parkingSliver)
    }

    func testOutgoingOnScreenWindowSlidesStraightDown() throws {
        let out = id(1)
        let result = plan(current: [out: column(100)], hidden: [out: hiddenTargetFor(column(100))])
        let animation = try XCTUnwrap(result.animations.first { $0.id == out })
        XCTAssertEqual(animation.from, column(100))
        XCTAssertEqual(animation.to, slideDownFrame(column(100), display: display))
        XCTAssertEqual(animation.to.minX, animation.from.minX)
        XCTAssertEqual(animation.duration, 0.25)
        XCTAssertEqual(animation.easing, .easeInOut)
        XCTAssertTrue(result.prepositions.isEmpty)
    }

    func testAlreadyHiddenWindowDoesNotAnimate() {
        let out = id(1)
        let corner = hiddenTargetFor(column(100))
        let result = plan(current: [out: corner.frame], hidden: [out: corner])
        XCTAssertTrue(result.animations.isEmpty)
        XCTAssertTrue(result.prepositions.isEmpty)
    }

    func testIncomingWindowRisesFromDirectlyBelowItsTarget() throws {
        let incoming = id(2)
        let corner = hiddenTargetFor(column(0))
        let result = plan(current: [incoming: corner.frame], visible: [incoming: column(500)])
        let start = slideDownFrame(column(500), display: display)
        XCTAssertEqual(result.prepositions, [incoming: start])
        let animation = try XCTUnwrap(result.animations.first)
        XCTAssertEqual(animation.from, start)
        XCTAssertEqual(animation.to, column(500))
        XCTAssertEqual(animation.from.minX, animation.to.minX)
    }

    func testIncomingWindowAdoptsTargetSizeAtItsStart() throws {
        let incoming = id(2)
        let stale = hiddenTargetFor(CGRect(x: 0, y: 0, width: 300, height: 400))
        let result = plan(current: [incoming: stale.frame], visible: [incoming: column(500)])
        XCTAssertEqual(result.prepositions[incoming]?.size, column(500).size)
    }

    func testIncomingWindowAlreadyOnScreenStartsWhereItIs() throws {
        // Retarget mid-switch: the window is halfway up; no snap, no preposition.
        let incoming = id(2)
        let midAir = CGRect(x: 500, y: -400, width: 800, height: 984)
        let result = plan(current: [incoming: midAir], visible: [incoming: column(500)])
        XCTAssertTrue(result.prepositions.isEmpty)
        let animation = try XCTUnwrap(result.animations.first)
        XCTAssertEqual(animation.from, midAir)
        XCTAssertEqual(animation.frame(at: 0), midAir)
    }

    func testRapidSwitchTurnsRisingWindowsIntoDroppingOnesFromTheirSampledFrame() throws {
        let rising = id(2)
        let midAir = CGRect(x: 500, y: -300, width: 800, height: 984)
        let result = plan(current: [rising: midAir], hidden: [rising: hiddenTargetFor(midAir)])
        let animation = try XCTUnwrap(result.animations.first)
        XCTAssertEqual(animation.from, midAir)
        XCTAssertEqual(animation.to, slideDownFrame(midAir, display: display))
    }

    func testIncomingWithOffscreenTargetJumpsAtTheFinalPass() {
        let incoming = id(2)
        let corner = hiddenTargetFor(column(0))
        let farRight = column(3000)
        let result = plan(
            current: [incoming: corner.frame], visible: [incoming: farRight],
            parked: [:]
        )
        XCTAssertTrue(result.animations.isEmpty)
        XCTAssertTrue(result.prepositions.isEmpty)
    }

    func testOrdinaryEdgeEntryStillSlidesSideways() throws {
        let entering = id(3)
        let edge = CGRect(x: 1799, y: 8, width: 800, height: 984)
        let result = plan(current: [entering: edge], visible: [entering: column(900)])
        XCTAssertTrue(result.prepositions.isEmpty)
        XCTAssertEqual(result.animations.first?.from, edge)
    }

    func testUnchangedVisibleWindowStaysPut() {
        let stayer = id(4)
        let result = plan(current: [stayer: column(8)], visible: [stayer: column(8)])
        XCTAssertTrue(result.animations.isEmpty)
    }

    func testSwitchAnimatesOutgoingAndIncomingTogether() {
        let out = id(1), incoming = id(2)
        let corner = hiddenTargetFor(column(0))
        let result = plan(
            current: [out: column(8), incoming: corner.frame],
            visible: [incoming: column(8)],
            hidden: [out: hiddenTargetFor(column(8))]
        )
        XCTAssertEqual(Set(result.animations.map(\.id)), [out, incoming])
    }
}
