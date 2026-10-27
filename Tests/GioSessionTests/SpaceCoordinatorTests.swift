@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

final class SpaceCoordinatorTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var reflows = 0
        var discards = 0
        var events: [String] = []
        var logs: [(LogLevel, String)] = []
    }

    private var recorder: Recorder!
    private var coordinator: SpaceCoordinator!

    override func setUp() {
        recorder = Recorder()
        let recorder = recorder!
        coordinator = SpaceCoordinator(context: .init(
            reflowAll: {
                recorder.reflows += 1
                recorder.events.append("reflow")
            },
            discardPendingAdoptions: { recorder.discards += 1 },
            rescan: { recorder.events.append("rescan") },
            adoptFrontmostFocus: { recorder.events.append("adopt") },
            log: { recorder.logs.append(($0, $1)) }
        ))
    }

    func testAllowsWorkUntilTheManagedSpaceIsLeft() {
        XCTAssertTrue(coordinator.allowsWindowWork)

        coordinator.managedSpaceActivityChanged(false)

        XCTAssertFalse(coordinator.allowsWindowWork)
    }

    func testLeavingDiscardsPendingAdoptionsWithoutReflowing() {
        coordinator.managedSpaceActivityChanged(false)

        XCTAssertEqual(recorder.discards, 1)
        XCTAssertEqual(recorder.reflows, 0)
        XCTAssertEqual(recorder.logs.map(\.1), ["space foreign; pausing layout"])
        XCTAssertEqual(recorder.logs.map(\.0), [.info])
    }

    func testReturningReflowsOnceAndLogs() {
        coordinator.managedSpaceActivityChanged(false)
        coordinator.managedSpaceActivityChanged(true)

        XCTAssertTrue(coordinator.allowsWindowWork)
        XCTAssertEqual(recorder.reflows, 1)
        XCTAssertEqual(recorder.logs.map(\.1), ["space foreign; pausing layout", "space managed; reflow"])
    }

    /// Live 2026-10-15: windows moved from another Desktop into the managed
    /// one (Mission Control) were never registered: no AX event announces a
    /// window that changed Space, so they sat unmanaged behind the strip.
    /// Returning scans for them first, then adopts the frontmost focus (a
    /// window just registered can be the one macOS focused), then reflows.
    func testReturningRescansThenAdoptsTheFrontmostFocusThenReflows() {
        coordinator.managedSpaceActivityChanged(false)
        XCTAssertEqual(recorder.events, [])

        coordinator.managedSpaceActivityChanged(true)

        XCTAssertEqual(recorder.events, ["rescan", "adopt", "reflow"])
    }

    func testRepeatedReportsDoNothing() {
        coordinator.managedSpaceActivityChanged(true)
        coordinator.managedSpaceActivityChanged(false)
        coordinator.managedSpaceActivityChanged(false)

        XCTAssertEqual(recorder.discards, 1)
        XCTAssertEqual(recorder.reflows, 0)
        XCTAssertEqual(recorder.logs.count, 1)
    }

    func testReflowRunsWhileTheGateIsAlreadyOpen() {
        var allowedDuringReflow: [Bool] = []
        let recorder = recorder!
        var coordinator: SpaceCoordinator!
        coordinator = SpaceCoordinator(context: .init(
            reflowAll: { allowedDuringReflow.append(coordinator.allowsWindowWork) },
            discardPendingAdoptions: { recorder.discards += 1 },
            rescan: {},
            adoptFrontmostFocus: {},
            log: { _, _ in }
        ))

        coordinator.managedSpaceActivityChanged(false)
        coordinator.managedSpaceActivityChanged(true)

        XCTAssertEqual(allowedDuringReflow, [true])
    }
}
