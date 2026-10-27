@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// Live 2026-10-08: every keystroke in Chrome's address bar opens its
/// suggestion popup, a separate non-resizable window Gio admits as floating
/// (`window open id=17232:13..22`). It was appended as the focused last
/// column, and Enter (popup gone) left the focus on the last column: the
/// strip jumped to a neighbour as if Alt+L/H had been pressed.
final class FloatingArrivalFocusTests: XCTestCase {
    private var world: EventWorld!
    private var discovery: DiscoveryService!

    override func setUp() {
        world = EventWorld()
        discovery = DiscoveryService(context: world.discoveryContext(), scheduler: ManualScheduler())
        world.displaySnapshots = [DisplaySnapshot(
            id: DisplayID(1), frame: EventWorld.screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130)
        )]
        discovery.syncDisplays()
        world.running = [7, 8]
    }

    private var current: Workspace {
        world.session.manager.currentWorkspace()
    }

    private func arrive(_ window: DiscoveredSystemWindow, element: Int32) -> WindowID? {
        let known = Set(world.registered.map(\.id))
        world.classify[window.window.pid] = [window]
        discovery.registerAppeared(AXUIElementCreateApplication(element), pid: window.window.pid)
        return world.registered.first { !known.contains($0.id) }?.id
    }

    func testAFloatingPopupNeitherTakesNorMovesTheStripFocus() throws {
        let browser = try XCTUnwrap(arrive(discovered(pid: 7, app: "Google Chrome"), element: 9001))
        _ = try XCTUnwrap(arrive(discovered(pid: 8, app: "Ghostty"), element: 9002))
        // The user is typing in the browser (left column).
        var workspace = current
        workspace.focusedColumn = 0
        workspace.focusedWindow = browser
        world.session.manager.update(workspace)

        // Chrome's suggestion popup (notResizable) on a keystroke, or a
        // transient dialog an app shows while you scroll (live: Tern,
        // `float(dialog)` at 01:48 and 01:52 UTC).
        for (element, reason) in [(Int32(9003), FloatReason.notResizable), (9004, .dialog)] {
            let popup = try XCTUnwrap(arrive(
                discovered(pid: 7, app: "Google Chrome", floatReason: reason), element: element
            ))
            XCTAssertEqual(current.focusedWindow, browser, "\(reason): the popup must not take the strip's focus")
            XCTAssertEqual(current.focusedColumn, 0)

            discovery.purge([popup])  // Enter, or the popup goes away.
            XCTAssertEqual(current.focusedWindow, browser, "\(reason)")
            XCTAssertEqual(current.focusedColumn, 0)
        }
    }

    /// FL-01: macOS orders a background app's new window under the frontmost
    /// app's window (probe 2026-10-21: stacking index 1 under the active
    /// app; AXRaise alone left it there), so a Slack or Meet popup opened
    /// while you work elsewhere hides behind the focused column. A rule with
    /// an explicit `open-focused = true` brings it to the front with focus.
    func testAnOptedInBackgroundPopupTakesFocusAndAsksToBeRaised() throws {
        world.session.config.rules = [WindowRule(app: "Slack", openFocused: true)]
        _ = try XCTUnwrap(arrive(discovered(pid: 7, app: "Slack"), element: 9001))
        let editor = try XCTUnwrap(arrive(discovered(pid: 8, app: "Ghostty"), element: 9002))
        var workspace = current
        workspace.focusedColumn = 1
        workspace.focusedWindow = editor
        world.session.manager.update(workspace)
        world.frontmost = 8  // the user types in Ghostty

        let popup = try XCTUnwrap(arrive(
            discovered(pid: 7, app: "Slack", floatReason: .dialog), element: 9003
        ))
        XCTAssertEqual(current.focusedWindow, popup)
        XCTAssertEqual(world.arrivalFocus, [popup])
    }

    func testAPopupOfTheFrontmostAppOrWithoutTheOptInStaysUnfocused() throws {
        world.session.config.rules = [WindowRule(app: "Google Chrome", openFocused: true)]
        let browser = try XCTUnwrap(arrive(discovered(pid: 7, app: "Google Chrome"), element: 9001))
        _ = try XCTUnwrap(arrive(discovered(pid: 8, app: "Slack"), element: 9002))
        var workspace = current
        workspace.focusedColumn = 0
        workspace.focusedWindow = browser
        world.session.manager.update(workspace)
        world.frontmost = 7  // typing in Chrome: its address-bar popups

        _ = try XCTUnwrap(arrive(
            discovered(pid: 7, app: "Google Chrome", floatReason: .notResizable), element: 9003
        ))
        // Slack has no opt-in: its background popup keeps today's behaviour.
        _ = try XCTUnwrap(arrive(discovered(pid: 8, app: "Slack", floatReason: .dialog), element: 9004))
        XCTAssertEqual(current.focusedWindow, browser)
        XCTAssertEqual(world.arrivalFocus, [])
    }
}
