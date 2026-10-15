import CoreGraphics
import XCTest
@testable import GioCore

final class GestureTransportTests: XCTestCase {
    private func id(_ n: UInt64) -> WindowID { WindowID(pid: 10, elementID: n) }

    private var strip: Set<WindowID> {
        [id(1), id(2), id(3), id(4)]
    }

    func testEveryStripWindowWithAnImageAndABackdropRidesTheOverlay() {
        let transport = planGestureTransport(
            windows: strip, rendererUsable: true, settleAnimates: true, backdropReady: true, hasImage: { _ in true }
        )
        XCTAssertEqual(transport, .overlay(layers: [id(1), id(2), id(3), id(4)]))
        XCTAssertEqual(gestureTransportLine(transport), "gesture scroll transport=overlay layers=4")
    }

    func testTheAXRendererKeepsThePump() {
        let transport = planGestureTransport(
            windows: strip, rendererUsable: false, settleAnimates: true, backdropReady: true, hasImage: { _ in true }
        )
        XCTAssertEqual(transport, .accessibility(reason: .renderer, missing: []))
        XCTAssertEqual(gestureTransportLine(transport), "gesture scroll transport=ax reason=renderer-ax")
    }

    func testAnInstantSettleKeepsThePumpSoTheReleaseNeverEndsTheOverlayBeforeItsWrites() {
        let transport = planGestureTransport(
            windows: strip, rendererUsable: true, settleAnimates: false, backdropReady: true, hasImage: { _ in true }
        )
        XCTAssertEqual(transport, .accessibility(reason: .instantSettle, missing: []))
        XCTAssertEqual(gestureTransportLine(transport), "gesture scroll transport=ax reason=instant-settle")
    }

    func testADisplayWithoutABackdropKeepsThePump() {
        let transport = planGestureTransport(
            windows: strip, rendererUsable: true, settleAnimates: true, backdropReady: false, hasImage: { _ in true }
        )
        XCTAssertEqual(transport, .accessibility(reason: .noBackdrop, missing: []))
    }

    func testAParkedColumnWithoutAnImageKeepsThePumpBecauseItMayScrollIntoView() {
        let parked: Set<WindowID> = [id(3), id(4)]
        let transport = planGestureTransport(
            windows: strip, rendererUsable: true, settleAnimates: true, backdropReady: true,
            hasImage: { !parked.contains($0) }
        )
        XCTAssertEqual(transport, .accessibility(reason: .cacheMiss, missing: [id(3), id(4)]))
        XCTAssertEqual(
            gestureTransportLine(transport), "gesture scroll transport=ax reason=cache-miss missing=2",
            "counts only, never titles"
        )
    }

    func testAnUndrawnWindowNeedsNoImageAndGetsNoLayer() {
        let transport = planGestureTransport(
            windows: strip, rendererUsable: true, settleAnimates: true, backdropReady: true,
            hasImage: { $0 != self.id(2) },
            undrawn: [id(2)]
        )
        XCTAssertEqual(transport, .overlay(layers: [id(1), id(3), id(4)]))
    }

    func testAStripOfUndrawnWindowsHasNothingToShow() {
        let transport = planGestureTransport(
            windows: [id(1)], rendererUsable: true, settleAnimates: true, backdropReady: true, hasImage: { _ in false },
            undrawn: [id(1)]
        )
        XCTAssertEqual(transport, .accessibility(reason: .nothingToShow, missing: []))
    }

    func testALostOverlayIsLoggedWithItsReason() {
        XCTAssertEqual(
            gestureTransportLine(.accessibility(reason: .overlayLost, missing: [])),
            "gesture scroll transport=ax reason=overlay-lost"
        )
    }

    func testTheKeepAliveComesWellBeforeTheOverlayWatchdog() {
        XCTAssertGreaterThan(gestureOverlayKeepAlive, 0)
        XCTAssertLessThan(gestureOverlayKeepAlive, FlightWatchdog.defaultLimit / 2)
    }

    func testTheReleaseVelocityGoesOnlyToLayersThatStillMove() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let moving = CGRect(x: 300, y: 0, width: 600, height: 800)
        let parked = CGRect(x: screen.maxX - 1, y: 0, width: 600, height: 800)
        let starts = [id(1): moving, id(2): parked, id(3): moving, id(4): moving]
        let targets = [id(1): moving.offsetBy(dx: -292, dy: 0), id(2): parked, id(3): moving.offsetBy(dx: 0.5, dy: 0)]
        let velocities = gestureSettleVelocities(windows: strip, velocity: -2400, from: starts, to: targets)
        XCTAssertEqual(
            velocities, [id(1): CGPoint(x: -2400, y: 0)],
            "a parked layer would bounce into view; one at its target and one without a target stay still"
        )
    }
}