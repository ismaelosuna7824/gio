@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

final class ForeignSpaceDiscoveryTests: XCTestCase {
    private var world: EventWorld!
    private var scheduler: ManualScheduler!
    private var discovery: DiscoveryService!
    private var allowed = true

    override func setUp() {
        world = EventWorld()
        scheduler = ManualScheduler()
        allowed = true
        var context = world.discoveryContext()
        context.allowsWindowWork = { [unowned self] in allowed }
        discovery = DiscoveryService(context: context, scheduler: scheduler)
        world.displaySnapshots = [DisplaySnapshot(
            id: DisplayID(1), frame: EventWorld.screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130)
        )]
        discovery.syncDisplays()
    }

    func testForeignSpaceRunsNoFullScanSoNothingIsPurged() {
        allowed = false

        discovery.enumerateAndPlace()

        XCTAssertTrue(world.scans.isEmpty)
        XCTAssertTrue(world.forgotten.isEmpty)
        XCTAssertEqual(world.reflows, 0)
    }

    func testForeignSpaceAttachedAppIsNotScannedNorReflowed() {
        allowed = false

        discovery.appAttached(7)

        XCTAssertTrue(world.scans.isEmpty)
        XCTAssertEqual(world.reflows, 0)
    }

    func testForeignSpaceRegistersNoAppearedWindow() {
        allowed = false
        world.running = [7]
        world.classify[7] = [discovered(pid: 7)]

        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: 7)
        scheduler.advance(by: 5)

        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertTrue(world.adopted.isEmpty)
        XCTAssertEqual(world.reflows, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testRetryScheduledBeforeLeavingStopsOnceTheSpaceIsForeign() {
        world.running = [7]
        world.classify[7] = [nil, discovered(pid: 7)]
        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: 7)

        allowed = false
        scheduler.advance(by: 5)

        XCTAssertTrue(world.registered.isEmpty)
    }

    func testManagedSpaceStillScansAndRegisters() {
        world.running = [7]
        world.classify[7] = [discovered(pid: 7)]

        discovery.enumerateAndPlace()
        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: 7)

        XCTAssertEqual(world.scans.count, 1)
        XCTAssertEqual(world.registered.map(\.pid), [7])
    }
}
