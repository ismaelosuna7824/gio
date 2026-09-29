import CoreGraphics
import XCTest
@testable import GioCore

/// SM-03: the pure math behind the GPU snapshot overlay (coordinate
/// conversion, spring mapping, retarget from-values, layer diff, watchdog).
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

    // MARK: spring

    func testGioSpringMapsToMassOneCASpring() {
        let mapped = overlaySpring(SpringParameters(dampingRatio: 1, stiffness: 800, epsilon: 0.0001))
        XCTAssertEqual(mapped.mass, 1)
        XCTAssertEqual(mapped.stiffness, 800)
        XCTAssertEqual(mapped.damping, 2 * 800.0.squareRoot(), accuracy: 1e-9)
    }

    func testUnderdampedSpringScalesDampingByRatio() {
        let mapped = overlaySpring(SpringParameters(dampingRatio: 0.5, stiffness: 400, epsilon: 0.0001))
        XCTAssertEqual(mapped.damping, 20, accuracy: 1e-9)
    }

    // MARK: retarget

    func testRetargetStartsFromThePresentationValueWhenThereIsOne() {
        let model = LayerGeometry(position: CGPoint(x: 500, y: 300), bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        let presentation = LayerGeometry(position: CGPoint(x: 320, y: 300), bounds: CGRect(x: 0, y: 0, width: 380, height: 300))
        XCTAssertEqual(retargetStart(presentation: presentation, model: model), presentation)
        XCTAssertEqual(retargetStart(presentation: nil, model: model), model)
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
}
