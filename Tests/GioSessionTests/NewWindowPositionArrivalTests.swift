@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// WP-02: a live arrival opens at `[layout] new-window-position`, read when
/// it arrives; a full scan (startup, rescan) keeps appending in discovery order.
final class NewWindowPositionArrivalTests: XCTestCase {
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
        world.running = [7, 8, 9, 10]
    }

    private var current: Workspace {
        world.session.manager.currentWorkspace()
    }

    private func arrive(_ window: DiscoveredSystemWindow, element: Int32) throws -> WindowID {
        let known = Set(world.registered.map(\.id))
        world.classify[window.window.pid] = [window]
        discovery.registerAppeared(AXUIElementCreateApplication(element), pid: window.window.pid)
        return try XCTUnwrap(world.registered.first { !known.contains($0.id) }?.id)
    }

    private func focus(_ id: WindowID) {
        world.session.manager.update(adoptingFocus(id, in: current)!)
    }

    func testALiveArrivalOpensRightOfTheFocusedColumn() throws {
        let first = try arrive(discovered(pid: 7, app: "Mail"), element: 9001)
        let second = try arrive(discovered(pid: 8, app: "Notes"), element: 9002)
        let third = try arrive(discovered(pid: 9, app: "Music"), element: 9003)
        focus(second)
        world.session.config.layout.newWindowPosition = .rightOfFocused

        let arrival = try arrive(discovered(pid: 10, app: "Ghostty"), element: 9004)

        XCTAssertEqual(current.columns.map(\.windows), [[first], [second], [arrival], [third]])
        XCTAssertEqual(current.focusedWindow, arrival)
        XCTAssertEqual(current.focusedColumn, 2)
    }

    func testAFullScanStillAppendsInDiscoveryOrder() throws {
        let windows = [
            discovered(pid: 7, app: "Mail"), discovered(pid: 8, app: "Notes"), discovered(pid: 9, app: "Music"),
        ]
        world.scan = SystemWindowDiscoveryResult(windows: windows, completePIDs: [7, 8, 9])
        discovery.enumerateAndPlace()
        let placed = current.columns.map(\.windows)
        XCTAssertEqual(placed.count, 3)
        focus(placed[1][0])
        world.session.config.layout.newWindowPosition = .rightOfFocused

        let late = discovered(pid: 10, app: "Ghostty")
        world.scan = SystemWindowDiscoveryResult(windows: windows + [late], completePIDs: [7, 8, 9, 10])
        discovery.enumerateAndPlace()

        let columns = current.columns.map(\.windows)
        XCTAssertEqual(columns.count, 4)
        XCTAssertEqual(Array(columns.prefix(3)), placed, "the scan appends after the existing columns")
        XCTAssertEqual(current.focusedColumn, 3)
    }
}
