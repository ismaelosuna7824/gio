import CoreGraphics
import XCTest
@testable import GioCore

/// SM-18: the overlay panel covers a display's usable area (menu bar and
/// Dock excluded), so the real, live menu bar and Dock draw over it instead
/// of the captured ones. Layers, holes, ring/dim and the backdrop crop are in
/// the panel's local space: origin at the usable frame's origin.
final class OverlayAreaTests: XCTestCase {
    // 1512x982 laptop panel; Cocoa global, origin bottom-left. Menu bar 37 pt.
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// Menu bar on top, Dock 70 pt at the bottom.
    private let bottomDock = CGRect(x: 0, y: 70, width: 1512, height: 875)
    /// Menu bar on top, Dock 60 pt on the left.
    private let leftDock = CGRect(x: 60, y: 0, width: 1452, height: 945)

    // MARK: panel frame

    func testThePanelCoversTheUsableFrame() {
        XCTAssertEqual(OverlayArea(display: laptop, usable: bottomDock).panelFrame, bottomDock)
        XCTAssertEqual(OverlayArea(display: laptop, usable: leftDock).panelFrame, leftDock)
    }

    func testAFullFrameDisplayKeepsTheWholeDisplay() {
        let area = OverlayArea(display: laptop, usable: laptop)
        XCTAssertEqual(area.panelFrame, laptop)
        XCTAssertEqual(area.backdropContentsRect(scale: 2, flipped: false), CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(area.backdropContentsRect(scale: 2, flipped: true), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testAUsableFrameReachingOutsideTheDisplayIsClampedAndADisjointOneIgnored() {
        let overhang = CGRect(x: -20, y: 70, width: 1600, height: 875)
        XCTAssertEqual(OverlayArea(display: laptop, usable: overhang).panelFrame, bottomDock)
        let elsewhere = CGRect(x: 3000, y: 0, width: 100, height: 100)
        XCTAssertEqual(OverlayArea(display: laptop, usable: elsewhere).panelFrame, laptop)
        XCTAssertEqual(OverlayArea(display: laptop, usable: .zero).panelFrame, laptop)
    }

    // MARK: layers, holes, ring and dim in panel coordinates

    func testLayerGeometryIsLocalToTheUsableOriginBothFlips() {
        let area = OverlayArea(display: laptop, usable: bottomDock)
        let window = CGRect(x: 8, y: 78, width: 700, height: 860)
        let up = overlayLayerGeometry(frame: window, in: area.panelFrame, flipped: false)
        // Local origin (8, 8): center (358, 438).
        XCTAssertEqual(up.position, CGPoint(x: 358, y: 438))
        XCTAssertEqual(up.bounds, CGRect(x: 0, y: 0, width: 700, height: 860))
        let down = overlayLayerGeometry(frame: window, in: area.panelFrame, flipped: true)
        // Top-left y = 875 - 8 - 860 = 7, center 437.
        XCTAssertEqual(down.position, CGPoint(x: 358, y: 437))
    }

    func testASideDockShiftsTheLocalOriginRight() {
        let area = OverlayArea(display: laptop, usable: leftDock)
        let window = CGRect(x: 68, y: 8, width: 700, height: 929)
        let geometry = overlayLayerGeometry(frame: window, in: area.panelFrame, flipped: false)
        XCTAssertEqual(geometry.position, CGPoint(x: 358, y: 472.5))
        let flipped = overlayLayerGeometry(frame: window, in: area.panelFrame, flipped: true)
        // Top-left y = 945 - 8 - 929 = 8, center 472.5.
        XCTAssertEqual(flipped.position, CGPoint(x: 358, y: 472.5))
    }

    func testRingAndDimFollowTheLocalWindowGeometry() {
        let area = OverlayArea(display: laptop, usable: bottomDock)
        let window = overlayLayerGeometry(
            frame: CGRect(x: 8, y: 78, width: 700, height: 860), in: area.panelFrame, flipped: false
        )
        let ring = overlayRingGeometry(window: window, width: 4)
        XCTAssertEqual(ring.position, CGPoint(x: 358, y: 438))
        XCTAssertEqual(ring.bounds, CGRect(x: 0, y: 0, width: 708, height: 868))
        // The dim layer takes the window layer's geometry as is.
        XCTAssertEqual(window.bounds, CGRect(x: 0, y: 0, width: 700, height: 860))
    }

    func testHolesAreLocalToTheUsableOriginBothFlips() {
        let area = OverlayArea(display: laptop, usable: bottomDock)
        let hole = CGRect(x: 720, y: 78, width: 700, height: 860)
        XCTAssertEqual(
            overlayBackdropHoles([hole], in: area.panelFrame, flipped: false),
            [CGRect(x: 720, y: 8, width: 700, height: 860)]
        )
        XCTAssertEqual(
            overlayBackdropHoles([hole], in: area.panelFrame, flipped: true),
            [CGRect(x: 720, y: 7, width: 700, height: 860)]
        )
        // A hole only in the menu bar strip is outside the panel.
        let menuBar = CGRect(x: 100, y: 950, width: 200, height: 30)
        XCTAssertTrue(overlayBackdropHoles([menuBar], in: area.panelFrame, flipped: false).isEmpty)
    }

    func testTheMaskCoversThePanelNotTheDisplay() throws {
        let area = OverlayArea(display: laptop, usable: bottomDock)
        let mask = try XCTUnwrap(overlayBackdropMask(
            holes: [CGRect(x: 720, y: 78, width: 700, height: 860)], in: area.panelFrame, flipped: false
        ))
        XCTAssertEqual(mask.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 1512, height: 875))
    }

    // MARK: backdrop crop

    func testTheBackdropShowsOnlyTheUsablePartWithMenuBarAndBottomDock() {
        let area = OverlayArea(display: laptop, usable: bottomDock)
        // Unflipped: unit y from the bottom, skipping the 70 pt Dock.
        XCTAssertEqual(
            area.backdropContentsRect(scale: 2, flipped: false),
            CGRect(x: 0, y: 140.0 / 1964, width: 1, height: 1750.0 / 1964)
        )
        // Flipped: unit y from the top, skipping the 37 pt menu bar.
        XCTAssertEqual(
            area.backdropContentsRect(scale: 2, flipped: true),
            CGRect(x: 0, y: 74.0 / 1964, width: 1, height: 1750.0 / 1964)
        )
    }

    func testTheBackdropCropSkipsASideDock() {
        let area = OverlayArea(display: laptop, usable: leftDock)
        XCTAssertEqual(
            area.backdropContentsRect(scale: 2, flipped: false),
            CGRect(x: 120.0 / 3024, y: 0, width: 2904.0 / 3024, height: 1890.0 / 1964)
        )
        XCTAssertEqual(
            area.backdropContentsRect(scale: 2, flipped: true),
            CGRect(x: 120.0 / 3024, y: 74.0 / 1964, width: 2904.0 / 3024, height: 1890.0 / 1964)
        )
    }

    func testTheCropIsRelativeToASecondDisplaysOriginAndSnapsToPixels() {
        let display = CGRect(x: 1512, y: 100, width: 1920, height: 1080)
        let usable = CGRect(x: 1512, y: 100.4, width: 1920, height: 1054.6)
        let area = OverlayArea(display: display, usable: usable)
        XCTAssertEqual(area.panelFrame, usable)
        // Scale 1: the 0.4 pt edge snaps to the pixel grid.
        XCTAssertEqual(
            area.backdropContentsRect(scale: 1, flipped: false),
            CGRect(x: 0, y: 0, width: 1, height: 1055.0 / 1080)
        )
    }
}
