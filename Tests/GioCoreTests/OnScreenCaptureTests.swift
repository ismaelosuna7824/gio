import CoreGraphics
import XCTest
@testable import GioCore

/// FX-11: a window drawn with a see-through material (Tern's blurred pane,
/// vibrancy sidebars) has no such pixels on its own: the WindowServer blurs
/// what is behind it. A desktop-independent capture renders it alone, so
/// the pane came out flat grey (live: real (32, 40, 40), image (43, 43, 45),
/// even with a clear capture background). A window that is fully on one
/// display and that nothing covers is captured as the display shows it.
final class OnScreenCaptureTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let other = CGRect(x: 1800, y: 0, width: 2560, height: 1440)
    private let tern = WindowID(pid: 10, elementID: 1)
    private let figma = WindowID(pid: 11, elementID: 1)
    private let ownPid: pid_t = 99
    private let ternFrame = CGRect(x: 904, y: 8, width: 888, height: 1114)
    private let figmaFrame = CGRect(x: 8, y: 8, width: 888, height: 1114)

    private func entry(_ number: UInt32, pid: pid_t, frame: CGRect, layer: Int = 0, alpha: Double = 1) -> StackedServerWindow {
        StackedServerWindow(windowID: number, pid: pid, layer: layer, alpha: alpha, frame: frame)
    }

    private func plan(
        frames: [WindowID: CGRect], numbers: [WindowID: UInt32], stack: [StackedServerWindow], half: Set<WindowID> = []
    ) -> [WindowID: Int] {
        snapshotOnScreenCaptures(
            frames: frames, windowNumbers: numbers, stack: stack, displays: [display, other], ownPid: ownPid, half: half
        )
    }

    func testAnUncoveredWindowOnOneDisplayIsCapturedAsShown() {
        let stack = [entry(2, pid: 11, frame: figmaFrame), entry(1, pid: 10, frame: ternFrame)]
        XCTAssertEqual(
            plan(frames: [tern: ternFrame, figma: figmaFrame], numbers: [tern: 1, figma: 2], stack: stack),
            [tern: 0, figma: 0]
        )
    }

    func testAWindowCoveredByAnotherInFrontIsCapturedAlone() {
        let palette = CGRect(x: 1000, y: 300, width: 200, height: 200)
        let stack = [entry(7, pid: 12, frame: palette, layer: 3), entry(1, pid: 10, frame: ternFrame)]
        XCTAssertEqual(plan(frames: [tern: ternFrame], numbers: [tern: 1], stack: stack), [:])
        let behind = [entry(1, pid: 10, frame: ternFrame), entry(7, pid: 12, frame: palette)]
        XCTAssertEqual(plan(frames: [tern: ternFrame], numbers: [tern: 1], stack: behind), [tern: 0], "behind it: hidden")
    }

    func testGiosOwnPanelsAndInvisibleWindowsDoNotCover() {
        let ring = CGRect(x: 900, y: 4, width: 896, height: 1122)
        let stack = [
            entry(30, pid: ownPid, frame: ring, layer: 3),
            entry(31, pid: 13, frame: display, layer: 25, alpha: 0),
            entry(1, pid: 10, frame: ternFrame),
        ]
        XCTAssertEqual(plan(frames: [tern: ternFrame], numbers: [tern: 1], stack: stack), [tern: 0])
    }

    func testParkedHalfResolutionAndUnlistedWindowsAreCapturedAlone() {
        let parked = CGRect(x: -887, y: 8, width: 888, height: 1114)
        let stack = [entry(1, pid: 10, frame: parked), entry(2, pid: 11, frame: figmaFrame)]
        XCTAssertEqual(plan(frames: [tern: parked], numbers: [tern: 1], stack: stack), [:], "not fully on one display")
        XCTAssertEqual(
            plan(frames: [figma: figmaFrame], numbers: [figma: 2], stack: stack, half: [figma]), [:], "hidden workspace"
        )
        XCTAssertEqual(plan(frames: [figma: figmaFrame], numbers: [figma: 3], stack: stack), [:], "not on screen")
    }

    func testAWindowOnTheSecondDisplayUsesThatDisplay() {
        let frame = CGRect(x: 1900, y: 100, width: 1000, height: 1200)
        XCTAssertEqual(
            plan(frames: [tern: frame], numbers: [tern: 1], stack: [entry(1, pid: 10, frame: frame)]), [tern: 1]
        )
    }

    /// The crop in the display's top-left points (ScreenCaptureKit's
    /// `sourceRect`), from Cocoa frames.
    func testTheCropIsTheWindowInTheDisplaysTopLeftPoints() {
        XCTAssertEqual(
            snapshotDisplayCrop(window: ternFrame, display: display),
            CGRect(x: 904, y: 1169 - 1122, width: 888, height: 1114)
        )
        let frame = CGRect(x: 1900, y: 100, width: 1000, height: 1200)
        XCTAssertEqual(
            snapshotDisplayCrop(window: frame, display: other), CGRect(x: 100, y: 1440 - 1300, width: 1000, height: 1200)
        )
    }
}
