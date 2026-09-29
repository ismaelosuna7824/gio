import XCTest
@testable import GioCore

/// PA-04: while a motion animates an app, its moved/resized events are our
/// own frame writes; they are dropped before any lookup or AX read.
final class MotionEchoDropTests: XCTestCase {
    func testMovedAndResizedFromAnimatedPidsAreDropped() {
        XCTAssertTrue(dropsAsMotionEcho(.moved, pid: 10, animating: [10]))
        XCTAssertTrue(dropsAsMotionEcho(.resized, pid: 10, animating: [10, 11]))
    }

    func testOtherPidsAreNotDropped() {
        XCTAssertFalse(dropsAsMotionEcho(.moved, pid: 12, animating: [10, 11]))
    }

    func testNothingIsDroppedWhenNoMotionIsActive() {
        XCTAssertFalse(dropsAsMotionEcho(.moved, pid: 10, animating: []))
        XCTAssertFalse(dropsAsMotionEcho(.resized, pid: 10, animating: []))
    }

    func testOnlyGeometryEventsAreDropped() {
        for kind in [WindowEventKind.windowCreated, .focusedWindowChanged, .miniaturized,
                     .deminiaturized, .titleChanged, .destroyed] {
            XCTAssertFalse(dropsAsMotionEcho(kind, pid: 10, animating: [10]), "\(kind)")
        }
    }
}
