import CoreGraphics
import XCTest
@testable import GioCore

/// SM-08: what the snapshot overlay draws on top of its window images so the
/// live ring and dim take over at the hand-off without a visible change.
final class OverlayDecorationsTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let focused = WindowID(pid: 1, elementID: 1)
    private let left = WindowID(pid: 2, elementID: 2)
    private let right = WindowID(pid: 3, elementID: 3)
    private let frame = CGRect(x: 600, y: 100, width: 600, height: 900)

    private func decorations(
        indicator: FocusIndicatorKind, ring: FocusRingSectionConfig = FocusRingSectionConfig(),
        window: FocusRingWindow? = nil, tiled: Set<WindowID>? = nil
    ) -> OverlayDecorations {
        overlayDecorations(
            focus: FocusSectionConfig(indicator: indicator, dimStrength: 0.2), ring: ring, theme: nil,
            focusedID: focused, focused: window ?? FocusRingWindow(frame: frame),
            tiled: tiled ?? [focused, left, right], displays: [display], fullscreenGap: 0
        )
    }

    func testNoIndicatorDrawsNothing() {
        XCTAssertEqual(decorations(indicator: .none), .none)
        XCTAssertEqual(OverlayDecorations.none, OverlayDecorations(ring: nil, dim: nil))
    }

    func testRingIndicatorRingsTheFocusedWindowLikeTheLiveRing() {
        let result = decorations(indicator: .ring, ring: FocusRingSectionConfig(width: 6))
        XCTAssertEqual(result.ring, OverlayRing(id: focused, width: 6, color: FocusRingSectionConfig.defaultColor))
        XCTAssertNil(result.dim)
    }

    func testRingFollowsTheLiveRingRules() {
        XCTAssertNil(decorations(indicator: .ring, ring: FocusRingSectionConfig(enabled: false)).ring)
        XCTAssertNil(decorations(indicator: .ring, window: FocusRingWindow(frame: frame, isMaximized: true)).ring)
        XCTAssertNil(decorations(indicator: .ring, window: FocusRingWindow(frame: frame, isMinimized: true)).ring)
        let parked = CGRect(x: -599, y: 100, width: 600, height: 900)
        XCTAssertNil(decorations(indicator: .ring, window: FocusRingWindow(frame: parked)).ring)
        XCTAssertNil(overlayDecorations(
            focus: FocusSectionConfig(indicator: .ring), ring: FocusRingSectionConfig(), theme: nil,
            focusedID: nil, focused: nil, tiled: [left], displays: [display], fullscreenGap: 0
        ).ring)
    }

    func testDimIndicatorDimsTheOtherTiledWindowsAtTheConfiguredStrength() {
        let result = decorations(indicator: .dim)
        XCTAssertEqual(result.dim, OverlayDim(ids: [left, right], strength: 0.2))
        XCTAssertNil(result.ring)
    }

    func testNothingDimsWithoutAVisibleFocusedWindow() {
        let parked = CGRect(x: -599, y: 100, width: 600, height: 900)
        XCTAssertNil(decorations(indicator: .dim, window: FocusRingWindow(frame: parked)).dim)
        XCTAssertNil(decorations(indicator: .dim, window: FocusRingWindow(frame: frame, isMinimized: true)).dim)
        XCTAssertNil(decorations(indicator: .dim, window: FocusRingWindow(frame: nil)).dim)
        XCTAssertNil(decorations(indicator: .dim, tiled: [focused]).dim, "nothing else to dim")
    }
}
