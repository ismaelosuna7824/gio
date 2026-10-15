import CoreGraphics
import XCTest
@testable import GioCore

/// WC-09: a click-driven focus event can arrive before the app's focused
/// window catches up. Mouse-driven adoption settles first and is validated
/// against the click point; keyboard-driven adoption stays immediate.
final class FocusSettleTests: XCTestCase {
    private let click = MouseClick(location: CGPoint(x: 500, y: 400), time: 100)

    // MARK: Which clicks count

    func testAMouseDownWithinTheRecentWindowIsMouseDriven() {
        let recent = recentClick(
            pressed: false, currentLocation: .zero, now: 100.2, lastTapped: click
        )
        XCTAssertEqual(recent, click)
    }

    func testAnOldMouseDownIsKeyboardDriven() {
        XCTAssertNil(recentClick(
            pressed: false, currentLocation: .zero, now: 100.5, lastTapped: click
        ))
        XCTAssertNil(recentClick(pressed: false, currentLocation: .zero, now: 1, lastTapped: nil))
    }

    func testAPressedButtonWithoutATappedClickFallsBackToTheCurrentLocation() {
        let fallback = recentClick(
            pressed: true, currentLocation: CGPoint(x: 7, y: 8), now: 50, lastTapped: nil
        )
        XCTAssertEqual(fallback, MouseClick(location: CGPoint(x: 7, y: 8), time: 50))
    }

    func testAHeldButtonKeepsTheTappedClickLocation() {
        let held = recentClick(
            pressed: true, currentLocation: CGPoint(x: 900, y: 900), now: 105, lastTapped: click
        )
        XCTAssertEqual(held, click)
    }

    func testAClickOutsideEveryVisibleAreaIsNotAWindowClick() {
        // Menu bar and Dock clicks activate apps without pointing at a window.
        let visible = [CGRect(x: 0, y: 80, width: 1000, height: 700)]
        XCTAssertNil(windowAreaClick(
            MouseClick(location: CGPoint(x: 500, y: 20), time: 1), visibleAreas: visible
        ))
        XCTAssertEqual(windowAreaClick(click, visibleAreas: visible), click)
        XCTAssertNil(windowAreaClick(nil, visibleAreas: visible))
    }

    /// WC-13: an auto-hidden Dock (or the menu bar while a fullscreen-like
    /// area reaches it) sits inside the usable area: a click marked as
    /// landing on system UI is not a window click either.
    func testAClickOnSystemUIInsideTheVisibleAreaIsNotAWindowClick() {
        let visible = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        let dock = MouseClick(location: CGPoint(x: 500, y: 20), time: 1, onSystemUI: true)
        XCTAssertNil(windowAreaClick(dock, visibleAreas: visible))
    }

    /// WC-13: the frontmost window under the click decides, Gio's own
    /// click-through panels (ring, dim, overlay) aside: the Dock (layer 20)
    /// and above (menu bar, status items, menus) are system UI; app windows
    /// (0), app panels below the Dock and the desktop (negative) are not.
    func testSystemUIIsTheDockLayerAndAboveSkippingGiosOwnPanels() {
        let point = CGPoint(x: 100, y: 100)
        let box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let gio: pid_t = 99
        func onSystemUI(_ windows: [PointWindow]) -> Bool {
            clickIsOnSystemUI(at: point, frontToBack: windows, ownPID: gio)
        }
        XCTAssertTrue(onSystemUI([PointWindow(pid: 5, layer: 20, bounds: box), PointWindow(pid: 7, layer: 0, bounds: box)]))
        XCTAssertTrue(onSystemUI([PointWindow(pid: 5, layer: 25, bounds: box)]))
        XCTAssertFalse(onSystemUI([PointWindow(pid: gio, layer: 3, bounds: box), PointWindow(pid: 7, layer: 0, bounds: box)]))
        XCTAssertFalse(onSystemUI([PointWindow(pid: 7, layer: 3, bounds: box)]), "an app's floating panel")
        XCTAssertFalse(onSystemUI([PointWindow(pid: 8, layer: -2_147_483_603, bounds: box)]), "the desktop")
        XCTAssertFalse(onSystemUI([PointWindow(pid: 5, layer: 20, bounds: CGRect(x: 300, y: 0, width: 10, height: 10))]))
        XCTAssertFalse(onSystemUI([]))
    }

    // MARK: Click validation

    func testFocusedWindowContainingTheClickMatches() {
        let frame = CGRect(x: 400, y: 300, width: 300, height: 300)
        XCTAssertTrue(focusMatchesClick(frame: frame, click: click.location))
    }

    func testStaleFocusedWindowNotContainingTheClickDoesNotMatch() {
        // A parked window at the display edge, or another window of the app.
        XCTAssertFalse(focusMatchesClick(
            frame: CGRect(x: 1439, y: 100, width: 800, height: 600), click: click.location
        ))
        XCTAssertFalse(focusMatchesClick(frame: nil, click: click.location))
    }

    // MARK: Keyboard-driven

    func testKeyboardActivationAdoptsImmediately() {
        var settle = FocusSettle<String>()
        XCTAssertEqual(settle.request("activation", click: nil), .adoptNow("activation"))
        // Nothing pending: the state machine is idle again.
        XCTAssertEqual(settle.poll(mouseDown: false, now: 1), .idle)
    }

    // MARK: Mouse-driven settle

    func testMouseDrivenWaitsForReleaseThenTheSettleDelay() {
        var settle = FocusSettle<String>()
        XCTAssertEqual(
            settle.request("focusChanged", click: click), .wait(after: FocusTiming.pollInterval)
        )
        // Button still down: keep waiting.
        XCTAssertEqual(
            settle.poll(mouseDown: true, now: 100.00), .wait(after: FocusTiming.pollInterval)
        )
        // Released now: the settle delay starts here.
        XCTAssertEqual(
            settle.poll(mouseDown: false, now: 100.10), .wait(after: FocusTiming.pollInterval)
        )
        XCTAssertEqual(
            settle.poll(mouseDown: false, now: 100.15), .wait(after: FocusTiming.pollInterval)
        )
        XCTAssertEqual(
            settle.poll(mouseDown: false, now: 100.19), .resolve("focusChanged", click)
        )
    }

    func testPressingAgainRestartsTheSettleDelay() {
        var settle = FocusSettle<String>()
        _ = settle.request("a", click: click)
        _ = settle.poll(mouseDown: false, now: 100.0)
        _ = settle.poll(mouseDown: true, now: 100.05)
        XCTAssertEqual(
            settle.poll(mouseDown: false, now: 100.10), .wait(after: FocusTiming.pollInterval)
        )
        XCTAssertEqual(settle.poll(mouseDown: false, now: 100.19), .resolve("a", click))
    }

    func testCoalescedEventsKeepTheLastOne() {
        var settle = FocusSettle<String>()
        XCTAssertEqual(
            settle.request("activation", click: click), .wait(after: FocusTiming.pollInterval)
        )
        XCTAssertEqual(settle.request("focusChanged", click: click), .coalesced)
        // A keyboard-style event while waiting also folds in.
        XCTAssertEqual(settle.request("rescan", click: nil), .coalesced)
        _ = settle.poll(mouseDown: false, now: 100.0)
        XCTAssertEqual(settle.poll(mouseDown: false, now: 100.1), .resolve("rescan", click))
    }

    // MARK: Verdicts

    private func resolved() -> FocusSettle<String> {
        var settle = FocusSettle<String>()
        _ = settle.request("e", click: click)
        _ = settle.poll(mouseDown: false, now: 0)
        _ = settle.poll(mouseDown: false, now: 1)
        return settle
    }

    func testMatchingFocusIsAdoptedAndResetsTheMachine() {
        var settle = resolved()
        XCTAssertEqual(settle.judge(matchesClick: true), .adopt)
        XCTAssertEqual(settle.request("next", click: nil), .adoptNow("next"))
    }

    func testStaleFocusIsReReadOnceThenDropped() {
        var settle = resolved()
        XCTAssertEqual(settle.judge(matchesClick: false), .retry(after: FocusTiming.retryDelay))
        let again = settle.resolveAgain()
        XCTAssertEqual(again?.0, "e")
        XCTAssertEqual(again?.1, click)
        XCTAssertEqual(settle.judge(matchesClick: false), .giveUp)
        XCTAssertNil(settle.resolveAgain())
        XCTAssertEqual(settle.request("next", click: nil), .adoptNow("next"))
    }

    func testTheRetryCanStillSucceed() {
        var settle = resolved()
        _ = settle.judge(matchesClick: false)
        XCTAssertEqual(settle.judge(matchesClick: true), .adopt)
    }

    func testEventArrivingDuringTheRetryReplacesTheEvent() {
        var settle = resolved()
        _ = settle.judge(matchesClick: false)
        XCTAssertEqual(settle.request("late", click: click), .coalesced)
        XCTAssertEqual(settle.resolveAgain()?.0, "late")
    }
}
