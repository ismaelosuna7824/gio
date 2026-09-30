import CoreGraphics
import XCTest
@testable import GioCore

final class WindowOpenMotionTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let target = CGRect(x: 100, y: 200, width: 900, height: 700)

    // MARK: Start frame

    func testStartFrameSitsBelowTheTargetWithTheFinalSize() {
        let start = windowOpenStartFrame(target: target, display: display, otherDisplays: [], offset: 24)
        XCTAssertEqual(start, CGRect(x: 100, y: 176, width: 900, height: 700))
    }

    func testZeroOffsetStartsAtTheTarget() {
        XCTAssertEqual(windowOpenStartFrame(target: target, display: display, otherDisplays: [], offset: 0), target)
        XCTAssertEqual(windowOpenStartFrame(target: target, display: display, otherDisplays: [], offset: -5), target)
    }

    func testFullHeightTileMayHangPastTheBottomEdgeWhenNothingIsBelow() {
        let tall = CGRect(x: 0, y: 8, width: 900, height: 1100)
        let start = windowOpenStartFrame(target: tall, display: display, otherDisplays: [], offset: 24)
        XCTAssertEqual(start.minY, -16)
        XCTAssertEqual(start.size, tall.size)
    }

    func testNeverCrossesOntoADisplayBelow() {
        let below = CGRect(x: 0, y: -1000, width: 1600, height: 1000)
        let tall = CGRect(x: 0, y: 8, width: 900, height: 1100)
        let start = windowOpenStartFrame(target: tall, display: display, otherDisplays: [below], offset: 24)
        XCTAssertEqual(start.minY, 0, "clamped to the display's bottom edge")
    }

    func testADisplayBesideTheStripDoesNotClamp() {
        let beside = CGRect(x: 1800, y: -1000, width: 1600, height: 1000)
        let tall = CGRect(x: 0, y: 8, width: 900, height: 1100)
        let start = windowOpenStartFrame(target: tall, display: display, otherDisplays: [beside], offset: 24)
        XCTAssertEqual(start.minY, -16)
    }

    func testOffsetNeverExceedsAQuarterOfTheWindowHeight() {
        let small = CGRect(x: 100, y: 400, width: 200, height: 40)
        let start = windowOpenStartFrame(target: small, display: display, otherDisplays: [], offset: 24)
        XCTAssertEqual(start.minY, 390)
    }

    // MARK: Which windows enter

    func testOnlyNewTiledWindowsInView() {
        let viewport = CGRect(x: 0, y: 20, width: 1800, height: 1129)
        let fresh = WindowID(pid: 1, elementID: 1)
        let floating = WindowID(pid: 2, elementID: 2)
        let parked = WindowID(pid: 3, elementID: 3)
        let offscreen = WindowID(pid: 4, elementID: 4)
        let old = WindowID(pid: 5, elementID: 5)
        let entries = planWindowOpenEntries(
            opening: [fresh, floating, parked, offscreen],
            visible: [
                fresh: target, floating: target, parked: target, old: target,
                offscreen: CGRect(x: 1799.5, y: 200, width: 900, height: 700),
            ],
            parked: [parked],
            modes: [fresh: .tiled, floating: .floating, parked: .tiled, offscreen: .tiled, old: .tiled],
            viewport: viewport, display: display, otherDisplays: [], offset: 24
        )
        XCTAssertEqual(entries, [fresh: CGRect(x: 100, y: 176, width: 900, height: 700)])
    }

    // MARK: Book

    func testBookHandsTheOpenedWindowsToOneAnimatedPass() {
        var book = WindowOpenBook()
        let a = WindowID(pid: 1, elementID: 1)
        let b = WindowID(pid: 1, elementID: 2)
        book.mark(a)
        book.mark(b)
        book.forget(b)
        XCTAssertEqual(book.take(animating: true), [a])
        XCTAssertEqual(book.take(animating: true), [])
    }

    func testAnInstantPassConsumesTheOpenedWindowsWithoutEntries() {
        var book = WindowOpenBook()
        book.mark(WindowID(pid: 1, elementID: 1))
        XCTAssertEqual(book.take(animating: false), [], "startup and permission passes place at once")
        XCTAssertEqual(book.take(animating: true), [], "and the latch is spent")
    }
}
