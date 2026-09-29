import XCTest
@testable import GioCore

/// HD-04: mouse-follows-focus decision, Cocoa->CG conversion, and the
/// focus-follows-mouse debounce.
final class MouseFocusTests: XCTestCase {
    private let a = WindowID(pid: 10, elementID: 1)
    private let b = WindowID(pid: 11, elementID: 2)
    private let frame = CGRect(x: 100, y: 200, width: 400, height: 300)

    // MARK: mouse-follows-focus

    func testWarpTargetsTheWindowCenterWhenEnabled() {
        XCTAssertEqual(
            mouseFollowsFocusTarget(enabled: true, frame: frame, pointer: CGPoint(x: 900, y: 900)),
            CGPoint(x: 300, y: 350)
        )
    }

    func testNoWarpWhenDisabledOrPointerAlreadyInside() {
        XCTAssertNil(mouseFollowsFocusTarget(enabled: false, frame: frame, pointer: CGPoint(x: 900, y: 900)))
        XCTAssertNil(mouseFollowsFocusTarget(enabled: true, frame: frame, pointer: CGPoint(x: 150, y: 250)))
        XCTAssertNil(mouseFollowsFocusTarget(enabled: true, frame: .zero, pointer: CGPoint(x: 900, y: 900)))
    }

    func testCocoaToGlobalDisplayFlipsAgainstThePrimaryHeight() {
        XCTAssertEqual(
            globalDisplayPoint(fromCocoa: CGPoint(x: 300, y: 350), primaryHeight: 1000),
            CGPoint(x: 300, y: 650)
        )
    }

    // MARK: hover target

    func testHoverTargetNeedsTheManagedWindowOnTopUnderThePointer() {
        let frames = [a: frame, b: CGRect(x: 600, y: 200, width: 400, height: 300)]
        XCTAssertEqual(hoverTarget(at: CGPoint(x: 150, y: 250), frames: frames, topWindowPID: 10, ownPID: 99), a)
        XCTAssertEqual(hoverTarget(at: CGPoint(x: 700, y: 250), frames: frames, topWindowPID: 11, ownPID: 99), b)
    }

    func testHoverIgnoresForeignOverlappingOwnAndEmptySpots() {
        let frames = [a: frame]
        // A non-managed window (other pid) is on top of the managed one.
        XCTAssertNil(hoverTarget(at: CGPoint(x: 150, y: 250), frames: frames, topWindowPID: 500, ownPID: 99))
        // Gio's own window on top.
        XCTAssertNil(hoverTarget(at: CGPoint(x: 150, y: 250), frames: frames, topWindowPID: 99, ownPID: 10))
        XCTAssertNil(hoverTarget(at: CGPoint(x: 150, y: 250), frames: frames, topWindowPID: nil, ownPID: 99))
        XCTAssertNil(hoverTarget(at: CGPoint(x: 5, y: 5), frames: frames, topWindowPID: 10, ownPID: 99))
    }

    // MARK: debounce

    func testFocusesAfterTheRestDelay() {
        var hover = HoverFocus()
        XCTAssertEqual(hover.pointerMoved(over: a, now: 0), HoverFocus.restDelay)
        XCTAssertNil(hover.due(now: 0.05, buttonDown: false, focused: b))
        XCTAssertEqual(hover.due(now: 0.11, buttonDown: false, focused: b), a)
        XCTAssertNil(hover.due(now: 0.2, buttonDown: false, focused: b), "fires once")
    }

    func testMovingToAnotherWindowRestartsTheClock() {
        var hover = HoverFocus()
        _ = hover.pointerMoved(over: a, now: 0)
        XCTAssertEqual(hover.pointerMoved(over: b, now: 0.08), HoverFocus.restDelay)
        XCTAssertNil(hover.due(now: 0.12, buttonDown: false, focused: nil), "b has only rested 40 ms")
        XCTAssertEqual(hover.due(now: 0.19, buttonDown: false, focused: nil), b)
    }

    func testLeavingForNothingCancels() {
        var hover = HoverFocus()
        _ = hover.pointerMoved(over: a, now: 0)
        XCTAssertNil(hover.pointerMoved(over: nil, now: 0.05))
        XCTAssertNil(hover.due(now: 0.2, buttonDown: false, focused: nil))
    }

    func testAlreadyFocusedWindowIsNeverRefocused() {
        var hover = HoverFocus()
        _ = hover.pointerMoved(over: a, now: 0)
        XCTAssertNil(hover.due(now: 0.2, buttonDown: false, focused: a))
    }

    func testButtonDownBlocksAndARetryIsOfferedOnTheNextMove() {
        var hover = HoverFocus()
        _ = hover.pointerMoved(over: a, now: 0)
        XCTAssertNil(hover.due(now: 0.2, buttonDown: true, focused: nil))
        XCTAssertEqual(hover.pointerMoved(over: a, now: 0.3), HoverFocus.restDelay)
        XCTAssertEqual(hover.due(now: 0.45, buttonDown: false, focused: nil), a)
    }

    func testAWarpSuppressesHoverBriefly() {
        var hover = HoverFocus()
        _ = hover.pointerMoved(over: a, now: 0)
        hover.noteWarp(now: 1)
        XCTAssertNil(hover.due(now: 1.2, buttonDown: false, focused: nil), "candidate dropped")
        XCTAssertNil(hover.pointerMoved(over: b, now: 1.1), "still suppressed")
        XCTAssertEqual(hover.pointerMoved(over: b, now: 1 + HoverFocus.warpSuppression + 0.01), HoverFocus.restDelay)
    }
}
