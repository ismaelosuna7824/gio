import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

/// PF-O: the live renderer from the first tick to the settle, through the
/// real `MotionDriver`, `MotionPlayer` and `WindowReconciler` with a fake
/// WindowServer and fake apps on one ordered journal. During the flight the
/// windows that keep their size move through SkyLight only (one transaction
/// per tick); the settle writes each one through Accessibility, then one
/// transaction aligns the WindowServer with the frames the apps took (TG-05),
/// and nothing is committed after that, however long the timer would run.
final class LiveRendererSettleTests: XCTestCase {
    final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ line: String) { lock.withLock { entries.append(line) } }
        var lines: [String] { lock.withLock { entries } }
    }

    final class Mover: WindowServerMover, @unchecked Sendable {
        let journal: Journal
        let ids: [WindowID: UInt32]
        private(set) var drawn: [UInt32: CGRect] = [:]

        init(_ ids: [WindowID: UInt32], journal: Journal) {
            self.ids = ids
            self.journal = journal
        }

        func windowServerID(of id: WindowID) -> UInt32? { ids[id] }

        func commit(_ moves: [WindowServerMove]) -> Bool {
            journal.append("commit " + moves.map { "\($0.windowID)@\(Int($0.frame.minX))" }.joined(separator: ","))
            for move in moves {
                drawn[move.windowID] = move.frame
            }
            return true
        }

        func frames(of windowIDs: [UInt32]) -> [UInt32: CGRect] {
            drawn.filter { windowIDs.contains($0.key) }
        }
    }

    final class Apps: WindowActuator, @unchecked Sendable {
        let journal: Journal
        private let lock = NSLock()
        private var believed: [WindowID: CGRect]

        init(_ believed: [WindowID: CGRect], journal: Journal) {
            self.believed = believed
            self.journal = journal
        }

        func belief(_ id: WindowID) -> CGRect? { lock.withLock { believed[id] } }
        func frame(of id: WindowID) throws -> CGRect? { belief(id) }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            try setFrame(frame, from: .zero, for: id, verify: true)
        }

        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            journal.append("write \(id.pid):\(id.elementID)@\(Int(frame.minX))")
            lock.withLock { believed[id] = frame }
        }

        func focus(id: WindowID) throws {}
    }

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private let a = WindowID(pid: 10, elementID: 1)
    private let b = WindowID(pid: 20, elementID: 1)
    private let grower = WindowID(pid: 30, elementID: 1)

    private func frame(_ x: CGFloat, width: CGFloat = 700) -> CGRect {
        CGRect(x: x, y: 8, width: width, height: 984)
    }

    private var journal: Journal!
    private var apps: Apps!
    private var mover: Mover!
    private var reconciler: WindowReconciler<Apps>!
    private var scheduler: ManualScheduler!
    private var clock: MotionClock!
    private var driver: MotionDriver!
    private var mouseDown = false
    private var calls: [String] = []
    private var logs: [String] = []
    private var finalPass: () -> Void = {}

    /// A scroll in view: `a` and `b` slide 400 pt left and keep their size;
    /// `grower` is maximized (its final size on the first frame).
    private var start: [WindowID: CGRect] { [a: frame(500), b: frame(1300), grower: frame(100, width: 300)] }
    private var targets: [WindowID: CGRect] { [a: frame(100), b: frame(900), grower: frame(8, width: 1784)] }

    override func setUp() {
        journal = Journal()
        apps = Apps(start, journal: journal)
        mover = Mover([a: 101, b: 201, grower: 301], journal: journal)
        reconciler = WindowReconciler(actuator: apps, concurrency: .serial, windowServer: mover, ownPID: 1)
        reconciler.windowServerEnabled = true
        scheduler = ManualScheduler()
        clock = MotionClock()
        let probes = ResizeProbeRunner(
            context: .init(
                isShuttingDown: { false }, matchWindows: { _ in [:] }, windowServerSize: { _ in nil },
                isSizeSettable: { _ in true }, appName: { "App\($0)" }, log: { _, _ in }
            ),
            scheduler: scheduler
        )
        driver = MotionDriver(
            context: .init(
                isShuttingDown: { false }, isMouseDown: { [unowned self] in mouseDown },
                armInstantPlacementForMouse: { [unowned self] in calls.append("armMouse") },
                reflowAll: { [unowned self] in calls.append("reflowAll") },
                takeCoalescedReflow: { false }, resetCoalescer: {},
                performReflow: {}, finalPass: { [unowned self] in finalPass() },
                recordSampled: { _, _, _ in }, recordPreposition: { _, _, _ in }, markUnverified: { _ in },
                focusedWindow: { nil }, publishFocusRing: {}, learnResizeCapability: { _ in },
                physicalFrame: { _ in nil }, displayRefreshes: { [] }, playerAppName: { "App\($0)" },
                playerClock: clock.read, log: { [unowned self] in logs.append($1) }, now: { [unowned self] in clock.now }
            ),
            resizeProbes: probes, scheduler: scheduler
        )
    }

    private func flights() -> [WindowAnimation] {
        var animations = [a, b, grower].map {
            WindowAnimation(id: $0, from: start[$0]!, to: targets[$0]!, spring: .niri)
        }
        animations[2].sizeSchedule = .atStart
        return planMotionTransports(animations, viewports: [display], enabled: true, ownPID: 1, renderer: .live)
    }

    private func advance(frames: Int) {
        for _ in 0..<frames {
            clock.now += 1.0 / 60
            scheduler.advance(by: 1.0 / 60)
        }
    }

    /// The settle the session runs: one exact pass to the targets.
    private func settle() {
        reconciler.reconcile(frames: targets, focused: nil, currentlyFocused: nil)
    }

    func testTheSettleWritesThroughAccessibilityThenAlignsAndNothingLandsAfterIt() {
        finalPass = { [unowned self] in
            calls.append("finalPass")
            settle()
        }
        let planned = flights()
        XCTAssertEqual(planned.map(\.transport), [.windowServer, .windowServer, .accessibility])
        driver.start(planned, sink: reconciler, renderer: .live)
        advance(frames: 120)

        XCTAssertFalse(driver.isActive)
        XCTAssertEqual(calls, ["finalPass"])
        let lines = journal.lines
        let firstWrite = lines.firstIndex { $0.hasPrefix("write 10:") || $0.hasPrefix("write 20:") }!
        // In flight: SkyLight only for the two windows that keep their size,
        // every tick one transaction holding both of them.
        let flight = lines[..<firstWrite].filter { !$0.hasPrefix("write 30:") }
        XCTAssertGreaterThan(flight.count, 5)
        XCTAssertTrue(flight.allSatisfy { $0.hasPrefix("commit 101@") && $0.contains(",201@") }, "\(flight)")
        XCTAssertFalse(lines.contains { $0.contains("301@") }, "the resizing window never goes through SkyLight")
        // The settle: Accessibility for both, then one alignment, and that
        // is the last thing the WindowServer is told.
        XCTAssertEqual(lines.last, "commit 101@100,201@900")
        XCTAssertEqual(lines.filter { $0.hasPrefix("commit") }.last, lines.last)
        let settleLines = lines[firstWrite...].filter { !$0.hasPrefix("write 30:") }
        XCTAssertEqual(settleLines, ["write 10:1@100", "write 20:1@900", "commit 101@100,201@900"])
        XCTAssertTrue(logs.contains { $0.hasPrefix("anim done") && $0.contains("renderer=live") }, "\(logs)")

        // The timer is gone: more time commits nothing.
        let settled = journal.lines
        advance(frames: 120)
        XCTAssertEqual(journal.lines, settled)
        assertWindowServerMatchesTheApps()
    }

    /// A click mid-flight abandons it (nothing moves under the cursor); the
    /// windows SkyLight moved stay pending, no tick commits again while the
    /// button is down, and the instant pass after the release writes them
    /// and aligns the WindowServer, so the apps and the WindowServer agree.
    func testAClickMidFlightStopsTheCommitsAndTheReleasePassLeavesNothingDesynced() {
        finalPass = { XCTFail("an abandoned flight has no final pass") }
        driver.start(flights(), sink: reconciler, renderer: .live)
        advance(frames: 6)
        XCTAssertFalse(reconciler.windowServerPending.isEmpty, "mid-flight the apps do not know yet")
        mouseDown = true
        advance(frames: 1)
        XCTAssertEqual(calls, ["armMouse", "reflowAll"])
        XCTAssertFalse(driver.isActive)
        let abandoned = journal.lines
        advance(frames: 60)
        XCTAssertEqual(journal.lines, abandoned, "nothing is committed while the button is down")

        // Release: the deferred reflow runs instantly (InstantPlacementGate).
        mouseDown = false
        settle()
        let after = Array(journal.lines[abandoned.count...]).filter { !$0.hasPrefix("write 30:") }
        XCTAssertEqual(after, ["write 10:1@100", "write 20:1@900", "commit 101@100,201@900"])
        XCTAssertTrue(reconciler.windowServerPending.isEmpty)
        assertWindowServerMatchesTheApps()
    }

    private func assertWindowServerMatchesTheApps(file: StaticString = #filePath, line: UInt = #line) {
        for (id, windowID) in [(a, UInt32(101)), (b, UInt32(201))] {
            XCTAssertEqual(mover.drawn[windowID]?.origin, apps.belief(id)?.origin, file: file, line: line)
            XCTAssertEqual(apps.belief(id), targets[id], file: file, line: line)
        }
    }
}
