import CoreGraphics
import XCTest
@testable import GioCore

/// SM-03/SM-08: the pure math behind the GPU snapshot overlay (coordinate
/// conversion, spring tracks and keyframes, velocity carry, shadow and ring
/// geometry, layer diff, watchdog).
final class OverlayGeometryTests: XCTestCase {
    private func id(_ n: UInt64) -> WindowID { WindowID(pid: 10, elementID: n) }
    // Second display to the right; Cocoa global coordinates, origin bottom-left.
    private let display = CGRect(x: 1440, y: 100, width: 1920, height: 1080)

    // MARK: coordinates

    func testCocoaFrameBecomesOverlayLocalWithCenterPosition() {
        let frame = CGRect(x: 1540, y: 200, width: 400, height: 300)
        let geometry = overlayLayerGeometry(frame: frame, in: display, flipped: false)
        XCTAssertEqual(geometry.bounds, CGRect(x: 0, y: 0, width: 400, height: 300))
        // Local origin (100, 100): center = (300, 250).
        XCTAssertEqual(geometry.position, CGPoint(x: 300, y: 250))
    }

    func testFlippedLayerGeometryMeasuresYFromTheTop() {
        let frame = CGRect(x: 1540, y: 200, width: 400, height: 300)
        let geometry = overlayLayerGeometry(frame: frame, in: display, flipped: true)
        // Local bottom-left y 100..400 -> top-left y = 1080 - 400 = 680..980, center 830.
        XCTAssertEqual(geometry.position, CGPoint(x: 300, y: 830))
        XCTAssertEqual(geometry.bounds.size, CGSize(width: 400, height: 300))
    }

    func testFramesOutsideTheDisplayKeepTheirRelativePosition() {
        let parked = CGRect(x: 1440 - 599, y: 100, width: 600, height: 400)
        let geometry = overlayLayerGeometry(frame: parked, in: display, flipped: false)
        XCTAssertEqual(geometry.position.x, -599 + 300)
    }

    // MARK: backdrop holes (SM-16)

    /// A window without an image at (1640, 300) 400x300: local (200, 200)
    /// from the bottom, (200, 1080 - 500 = 580) from the top.
    private let hole = CGRect(x: 1640, y: 300, width: 400, height: 300)

    func testHolesAreInOverlayCoordinatesBothFlips() {
        XCTAssertEqual(
            overlayBackdropHoles([hole], in: display, flipped: false), [CGRect(x: 200, y: 200, width: 400, height: 300)]
        )
        XCTAssertEqual(
            overlayBackdropHoles([hole], in: display, flipped: true), [CGRect(x: 200, y: 580, width: 400, height: 300)]
        )
    }

    func testAHoleOffTheDisplayIsDropped() {
        XCTAssertEqual(overlayBackdropHoles([CGRect(x: 0, y: 100, width: 400, height: 300)], in: display, flipped: false), [])
        XCTAssertNil(overlayBackdropMask(holes: [CGRect(x: 0, y: 100, width: 400, height: 300)], in: display, flipped: false))
        XCTAssertNil(overlayBackdropMask(holes: [], in: display, flipped: false), "no holes: no mask")
    }

    func testTheMaskKeepsTheDisplayAndCutsRoundedHoles() throws {
        for flipped in [false, true] {
            let mask = try XCTUnwrap(overlayBackdropMask(holes: [hole], in: display, flipped: flipped))
            let local = overlayBackdropHoles([hole], in: display, flipped: flipped)[0]
            XCTAssertTrue(mask.contains(CGPoint(x: 10, y: 10), using: .evenOdd), "the backdrop outside the hole")
            XCTAssertTrue(mask.contains(CGPoint(x: 1900, y: 1070), using: .evenOdd))
            XCTAssertFalse(mask.contains(CGPoint(x: local.midX, y: local.midY), using: .evenOdd), "the real window shows")
            XCTAssertFalse(mask.contains(CGPoint(x: local.minX + 1, y: local.midY), using: .evenOdd))
            XCTAssertTrue(
                mask.contains(CGPoint(x: local.minX + 1, y: local.minY + 1), using: .evenOdd),
                "rounded like the window: the corner keeps the backdrop"
            )
            XCTAssertFalse(
                mask.contains(CGPoint(x: local.minX + overlayWindowCornerRadius, y: local.minY + overlayWindowCornerRadius), using: .evenOdd)
            )
        }
    }

    func testOverlappingHolesStayOpen() throws {
        let second = hole.offsetBy(dx: 200, dy: 100)
        let mask = try XCTUnwrap(overlayBackdropMask(holes: [hole, second], in: display, flipped: false))
        // Local overlap: x 400..600, y 300..500.
        XCTAssertFalse(mask.contains(CGPoint(x: 500, y: 400), using: .evenOdd), "even-odd does not refill the overlap")
        XCTAssertFalse(mask.contains(CGPoint(x: 700, y: 550), using: .evenOdd))
        XCTAssertTrue(mask.contains(CGPoint(x: 700, y: 250), using: .evenOdd))
    }

    // MARK: tracks and keyframes (SM-08)

    private let spring = SpringParameters.niri
    private var track: FlightTrack {
        FlightTrack(
            start: LayerGeometry(position: CGPoint(x: 100, y: 200), bounds: CGRect(x: 0, y: 0, width: 400, height: 300)),
            end: LayerGeometry(position: CGPoint(x: 500, y: 200), bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        )
    }

    func testTrackStateFollowsGiosSpringOnEveryAxis() {
        let rest = track.state(at: 0, spring: spring)
        XCTAssertEqual(rest.geometry, track.start)
        XCTAssertEqual(rest.velocity, .zero)
        let sample = track.state(at: 0.1, spring: spring)
        let x = spring.state(displacement: -400, velocity: 0, at: 0.1)
        let width = spring.state(displacement: 200, velocity: 0, at: 0.1)
        XCTAssertEqual(sample.geometry.position.x, 500 + x.displacement, accuracy: 1e-9)
        XCTAssertEqual(sample.geometry.position.y, 200)
        XCTAssertEqual(sample.geometry.bounds.width, 200 + width.displacement, accuracy: 1e-9)
        XCTAssertEqual(sample.geometry.bounds.height, 300)
        XCTAssertEqual(sample.geometry.bounds.origin, .zero)
        XCTAssertEqual(sample.velocity.position.dx, x.velocity, accuracy: 1e-9)
        XCTAssertEqual(sample.velocity.position.dy, 0)
        XCTAssertEqual(sample.velocity.size.width, width.velocity, accuracy: 1e-9)
        XCTAssertEqual(sample.velocity.size.height, 0)
        XCTAssertGreaterThan(sample.velocity.position.dx, 0, "still moving towards the target")
    }

    func testRetargetStartsFromTheCurrentStateAndCarriesTheVelocity() {
        let next = LayerGeometry(position: CGPoint(x: 900, y: 200), bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        let moving = track.state(at: 0.05, spring: spring)
        let retargeted = track.retargeted(to: next, at: 0.05, spring: spring)
        XCTAssertEqual(retargeted.start, moving.geometry)
        XCTAssertEqual(retargeted.end, next)
        XCTAssertEqual(retargeted.velocity, moving.velocity)
        XCTAssertNotEqual(retargeted.velocity, .zero)
        // The carried velocity is the initial condition of the new spring.
        let carried = retargeted.state(at: 0.02, spring: spring)
        let analytic = spring.state(
            displacement: moving.geometry.position.x - 900, velocity: moving.velocity.position.dx, at: 0.02
        )
        XCTAssertEqual(carried.geometry.position.x, 900 + analytic.displacement, accuracy: 1e-9)
        XCTAssertEqual(carried.velocity.position.dx, analytic.velocity, accuracy: 1e-9)
    }

    func testSettleTimeCountsTheCarriedVelocity() {
        let resting = FlightTrack(start: track.end, end: track.end)
        XCTAssertEqual(resting.settleTime(spring: spring), 1.0 / 60, accuracy: 1e-9)
        let pushed = FlightTrack(
            start: track.end, end: track.end,
            velocity: LayerVelocity(position: CGVector(dx: 3000, dy: 0), size: .zero)
        )
        XCTAssertGreaterThan(pushed.settleTime(spring: spring), 0.1)
        XCTAssertEqual(track.settleTime(spring: spring), flightSettleTime(spring: spring, travel: 400), accuracy: 1e-9)
        let soft = SpringParameters(dampingRatio: 3, stiffness: 100, epsilon: 0.0001)
        XCTAssertLessThanOrEqual(track.settleTime(spring: soft), SpringParameters.maxDuration)
    }

    func testKeyframesSampleTheTrackAtTheRateAndLandExactlyOnTheEnd() {
        let frames = flightKeyframes(track: track, spring: spring, rate: 120)
        XCTAssertEqual(frames.duration, track.settleTime(spring: spring), accuracy: 1e-9)
        XCTAssertEqual(frames.times.count, frames.geometries.count)
        XCTAssertEqual(frames.times.count, Int((frames.duration * 120).rounded(.up)) + 1)
        XCTAssertEqual(frames.times.first, 0)
        XCTAssertEqual(frames.times.last, 1)
        XCTAssertEqual(frames.geometries.first, track.start)
        XCTAssertEqual(frames.geometries.last, track.end)
        XCTAssertTrue(zip(frames.times, frames.times.dropFirst()).allSatisfy { $0 < $1 }, "strictly increasing")
        let middle = frames.times.count / 2
        let expected = track.state(at: frames.times[middle] * frames.duration, spring: spring).geometry
        XCTAssertEqual(frames.geometries[middle].position.x, expected.position.x, accuracy: 1e-9)
        XCTAssertEqual(frames.geometries[middle].bounds.width, expected.bounds.width, accuracy: 1e-9)
    }

    func testKeyframesOfARestingTrackStillBracketTheEnd() {
        let resting = FlightTrack(start: track.end, end: track.end)
        let frames = flightKeyframes(track: resting, spring: spring, rate: 120)
        XCTAssertEqual(frames.geometries.first, track.end)
        XCTAssertEqual(frames.geometries.last, track.end)
        XCTAssertGreaterThanOrEqual(frames.times.count, 2)
    }

    func testTrackTravelIsTheLargestEdgeOrSizeMovement() {
        // Center 100 -> 500 while the width halves: the left edge moves 500.
        XCTAssertEqual(track.travel, 500, accuracy: 1e-9)
    }

    // MARK: shadow, ring and dim (SM-08)

    func testWindowShadowResemblesMacOS() {
        XCTAssertEqual(overlayWindowShadow.offset, CGSize(width: 0, height: -10))
        XCTAssertEqual(overlayWindowShadow.radius, 22)
        XCTAssertEqual(overlayWindowShadow.opacity, 0.38, accuracy: 1e-6)
    }

    func testShadowPathIsTheRoundedWindowRect() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let path = overlayShadowPath(bounds: bounds, cornerRadius: overlayWindowCornerRadius)
        XCTAssertEqual(path.boundingBox, bounds)
        XCTAssertTrue(path.contains(CGPoint(x: 200, y: 150)))
        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 0.5)), "the corner is rounded off")
        XCTAssertTrue(path.contains(CGPoint(x: 10, y: 10)))
    }

    func testRingLayerWrapsTheWindowLayerByItsWidth() {
        let window = LayerGeometry(position: CGPoint(x: 300, y: 250), bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        let ring = overlayRingGeometry(window: window, width: 4)
        XCTAssertEqual(ring.position, window.position)
        XCTAssertEqual(ring.bounds, CGRect(x: 0, y: 0, width: 408, height: 308))
        // Border inside the outset bounds: inner edge radius = the window's.
        XCTAssertEqual(overlayRingCornerRadius(width: 4), overlayWindowCornerRadius + 4)
        XCTAssertEqual(overlayWindowCornerRadius, focusRingWindowCornerRadius)
    }

    // MARK: diff

    func testDiffSplitsAddedRemovedAndRetargeted() {
        let diff = diffOverlayItems(existing: [id(1), id(2), id(3)], next: [id(2), id(3), id(4)])
        XCTAssertEqual(diff.added, [id(4)])
        XCTAssertEqual(diff.removed, [id(1)])
        XCTAssertEqual(diff.retargeted, [id(2), id(3)])
    }

    func testDiffOfNothingIsEmpty() {
        let diff = diffOverlayItems(existing: [], next: [])
        XCTAssertEqual(diff, OverlayDiff(added: [], removed: [], retargeted: []))
    }

    // MARK: display choice

    func testALayerBelongsToTheDisplayHoldingItsTargetElseItsStart() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let from = CGRect(x: 50, y: 0, width: 400, height: 300)
        XCTAssertEqual(overlayDisplayIndex(from: from, to: CGRect(x: 1100, y: 0, width: 400, height: 300), displays: [left, right]), 1)
        // Target parked off every display: the start decides.
        XCTAssertEqual(overlayDisplayIndex(from: from, to: CGRect(x: -3000, y: 0, width: 400, height: 300), displays: [left, right]), 0)
        XCTAssertNil(overlayDisplayIndex(from: CGRect(x: -3000, y: 0, width: 10, height: 10), to: CGRect(x: -4000, y: 0, width: 10, height: 10), displays: [left, right]))
    }

    func testAParkedSliverIsNotDrawable() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sliver = CGRect(x: -599, y: 0, width: 600, height: 400)   // 1 pt inside
        XCTAssertNil(overlayDisplayIndex(from: sliver, to: sliver, displays: [left]))
        let eight = CGRect(x: -592, y: 0, width: 600, height: 400)    // 8 pt inside
        XCTAssertEqual(overlayDisplayIndex(from: eight, to: eight, displays: [left]), 0)
    }

    // MARK: watchdog

    func testWatchdogExpiresAfterTheLimitAndRearmingSupersedes() {
        var watchdog = FlightWatchdog(limit: 1.5)
        let first = watchdog.arm(at: 10)
        XCTAssertFalse(watchdog.isExpired(first, now: 11.4))
        XCTAssertTrue(watchdog.isExpired(first, now: 11.5))
        let second = watchdog.arm(at: 11)
        XCTAssertFalse(watchdog.isCurrent(first))
        XCTAssertTrue(watchdog.isCurrent(second))
        XCTAssertFalse(watchdog.isExpired(second, now: 12.4))
        watchdog.disarm()
        XCTAssertFalse(watchdog.isCurrent(second))
        XCTAssertFalse(watchdog.isExpired(second, now: 99))
    }

    /// SM-14: at the deadline the watchdog is re-armed for the hand-off hold
    /// with its own, shorter limit; the next arm is back to the default.
    func testAnArmCanCarryItsOwnLimit() {
        var watchdog = FlightWatchdog(limit: 1.5)
        let hold = watchdog.arm(at: 10, limit: 0.5)
        XCTAssertFalse(watchdog.isExpired(hold, now: 10.49))
        XCTAssertTrue(watchdog.isExpired(hold, now: 10.5))
        let flight = watchdog.arm(at: 11)
        XCTAssertFalse(watchdog.isExpired(flight, now: 12.4))
        XCTAssertTrue(watchdog.isExpired(flight, now: 12.5))
    }
}
