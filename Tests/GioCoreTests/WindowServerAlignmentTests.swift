import CoreGraphics
import XCTest
@testable import GioCore

/// TG-05 (log 2026-10-11T22:53Z): after a trackpad swipe the apps reported
/// their windows at the target while the WindowServer drew them elsewhere
/// (`render mismatch ... ax=(904,8,..) ws=(-928,8,..)`), and neither the
/// final pass's Accessibility follow-up nor the position and size nudges
/// moved them. A window SkyLight moved must end with the WindowServer at
/// the frame its app took, and a render mismatch is repaired through
/// SkyLight first.
final class WindowServerAlignmentTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let tern = WindowID(pid: 57880, elementID: 6)
    private let code = WindowID(pid: 4295, elementID: 8)

    private func frame(_ x: CGFloat) -> CGRect {
        CGRect(x: x, y: 8, width: 888, height: 1114)
    }

    /// One ordered journal for the WindowServer and the apps.
    final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ line: String) { lock.withLock { entries.append(line) } }
        var lines: [String] { lock.withLock { entries } }
    }

    /// What the WindowServer draws, shared by the fake SkyLight and the apps.
    final class Screen: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [UInt32: CGRect] = [:]
        subscript(windowID: UInt32) -> CGRect? {
            get { lock.withLock { frames[windowID] } }
            set { lock.withLock { frames[windowID] = newValue } }
        }
    }

    /// SkyLight: absolute moves, all of a batch in one transaction (the
    /// PF-M probe verified that a committed frame is where it is drawn).
    final class Mover: WindowServerMover, @unchecked Sendable {
        let journal: Journal
        let screen: Screen
        let ids: [WindowID: UInt32]
        var accepts = true
        private(set) var transactions: [[WindowServerMove]] = []

        init(_ ids: [WindowID: UInt32], screen: Screen, journal: Journal) {
            self.ids = ids
            self.screen = screen
            self.journal = journal
        }

        func windowServerID(of id: WindowID) -> UInt32? { ids[id] }

        func commit(_ moves: [WindowServerMove]) -> Bool {
            guard accepts else { return false }
            transactions.append(moves)
            journal.append("commit " + moves.map { "\($0.windowID)@\(Int($0.frame.minX))" }.joined(separator: ","))
            for move in moves {
                let size = screen[move.windowID]?.size ?? move.frame.size
                screen[move.windowID] = CGRect(origin: move.frame.origin, size: size)
            }
            return true
        }

        func frames(of windowIDs: [UInt32]) -> [UInt32: CGRect] {
            var result: [UInt32: CGRect] = [:]
            for windowID in windowIDs {
                result[windowID] = screen[windowID]
            }
            return result
        }
    }

    /// The apps as the log shows them after a swipe: they do not learn
    /// SkyLight moves, they answer Accessibility with what they believe, and
    /// they turn an Accessibility write into a move of their window by the
    /// change they see. A write of what an app already believes moves
    /// nothing, and a nudge (+1 then back) leaves the window where it was.
    final class Apps: WindowActuator, @unchecked Sendable {
        let journal: Journal
        let screen: Screen
        let ids: [WindowID: UInt32]
        private let lock = NSLock()
        private var believed: [WindowID: CGRect]
        var failing: Set<WindowID> = []
        /// macOS clamps a parked write here: the app lands there and the
        /// write reports a mismatch.
        var clamps: [WindowID: CGRect] = [:]

        init(_ believed: [WindowID: CGRect], ids: [WindowID: UInt32], screen: Screen, journal: Journal) {
            self.believed = believed
            self.ids = ids
            self.screen = screen
            self.journal = journal
            for (id, frame) in believed {
                screen[ids[id]!] = frame
            }
        }

        func believes(_ id: WindowID) -> CGRect? { lock.withLock { believed[id] } }

        func frame(of id: WindowID) throws -> CGRect? { believes(id) }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            try setFrame(frame, from: .zero, for: id, verify: true)
        }

        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            if failing.contains(id) {
                throw NSError(domain: "mock", code: 1)
            }
            journal.append("write \(id.pid):\(id.elementID)@\(Int(frame.minX))")
            let landed = clamps[id] ?? frame
            lock.withLock {
                let old = believed[id] ?? landed
                if let windowID = ids[id], let drawn = screen[windowID] {
                    screen[windowID] = drawn.offsetBy(dx: landed.minX - old.minX, dy: landed.minY - old.minY)
                }
                believed[id] = landed
            }
            if landed != frame {
                throw NSError(domain: "mock", code: 2)
            }
        }

        func focus(id: WindowID) throws {}
    }

    private final class Clock: @unchecked Sendable {
        var now: TimeInterval = 0
    }

    private func make(_ apps: Apps, _ mover: Mover) -> WindowReconciler<Apps> {
        let reconciler = WindowReconciler(actuator: apps, concurrency: .serial, windowServer: mover, ownPID: 1)
        reconciler.windowServerEnabled = true
        return reconciler
    }

    /// Gesture A of the log: the strip at offset 919 (Tern visible at 904,
    /// Code parked at the right edge), the fingers carry it 198 pt, the
    /// release snaps it to 1815 (Tern at 8, Code at 904) with the release
    /// velocity, every frame through SkyLight, then the final pass.
    func testAGestureSettleEndsWithTheWindowServerDrawingEveryWindowAtItsTarget() {
        let journal = Journal()
        let screen = Screen()
        let ids = [tern: UInt32(6), code: UInt32(8)]
        let start = [tern: frame(904), code: frame(1799)]
        let targets = [tern: frame(8), code: frame(904)]
        let apps = Apps(start, ids: ids, screen: screen, journal: journal)
        let mover = Mover(ids, screen: screen, journal: journal)
        let reconciler = make(apps, mover)

        // The fingers: one SkyLight transaction per drain (GestureFramePump).
        let pump = GestureFramePump(sink: reconciler, start: start)
        var released = start
        for travel in stride(from: CGFloat(66), through: 198, by: 66) {
            released = [tern: frame(904 - travel), code: frame(1799 - travel)]
            XCTAssertEqual(Set(pump.pump(released).keys), [tern, code])
        }

        // The settle: a spring with the release velocity, on SkyLight per tick.
        let clock = Clock()
        let player = MotionPlayer(sink: reconciler, clock: { clock.now })
        let flights = [tern, code].map { id in
            var flight = WindowAnimation(
                id: id, from: released[id]!, to: targets[id]!, spring: .niri, velocity: CGPoint(x: -2472, y: 0)
            )
            flight.transport = .windowServer
            return flight
        }
        player.start(flights)
        var summary: MotionSummary?
        while summary == nil {
            clock.now += 1.0 / 120
            summary = player.tick().summary
        }
        XCTAssertFalse(journal.lines.contains { $0.hasPrefix("write") }, "no Accessibility write before the final pass")

        // Candidate (b): every frame SkyLight was given lies on the window's
        // own path (screen space, never an offset applied twice).
        for transaction in mover.transactions {
            for move in transaction {
                let id = ids.first { $0.value == move.windowID }!.key
                let low = min(start[id]!.minX, targets[id]!.minX), high = max(start[id]!.minX, targets[id]!.minX)
                XCTAssertTrue((low...high).contains(move.frame.minX), "\(move.frame.minX) is off the path of \(id)")
            }
        }

        // The final pass: the apps take their targets (Accessibility reports
        // them, as in the log) ...
        let report = reconciler.reconcile(frames: targets, focused: nil, currentlyFocused: nil)
        XCTAssertEqual(Set(report.applied), [tern, code])
        XCTAssertEqual(apps.believes(tern), targets[tern])
        XCTAssertEqual(apps.believes(code), targets[code])
        // ... and the WindowServer draws them there too: candidate (c), the
        // pass took the apps' word for the WindowServer.
        XCTAssertEqual(screen[6], targets[tern], "the WindowServer draws Tern elsewhere")
        XCTAssertEqual(screen[8], targets[code], "the WindowServer draws Code elsewhere")

        // Candidate (a): nothing is committed after the final pass but the
        // one transaction that aligns the WindowServer with the apps.
        let lastWrite = journal.lines.lastIndex { $0.hasPrefix("write") }!
        XCTAssertEqual(Array(journal.lines[(lastWrite + 1)...]), ["commit 8@904,6@8"])
        XCTAssertTrue(reconciler.windowServerPending.isEmpty, "the apps already hold these frames")
    }

    /// The alignment follows only writes that landed, to the frame the app
    /// took; a failed follow-up stays pending and is not aligned.
    func testOnlyLandedFollowUpsAreAlignedAndAFailedOneStaysPending() {
        let journal = Journal()
        let screen = Screen()
        let ids = [tern: UInt32(6), code: UInt32(8)]
        let apps = Apps([tern: frame(1799), code: frame(1799)], ids: ids, screen: screen, journal: journal)
        apps.failing = [code]
        let mover = Mover(ids, screen: screen, journal: journal)
        let reconciler = make(apps, mover)
        reconciler.reconcile(
            frames: [tern: frame(8), code: frame(904)], focused: nil, currentlyFocused: nil,
            windowServerFirst: [tern, code]
        )
        XCTAssertEqual(journal.lines.first, "commit 8@904,6@8")
        XCTAssertEqual(journal.lines.last, "commit 6@8", "the alignment leaves the failed window alone")
        XCTAssertEqual(screen[6], frame(8))
        XCTAssertEqual(reconciler.windowServerPending, [code: frame(904)])
    }

    /// A parked write macOS clamped lands a few points inside the display:
    /// the WindowServer is aligned where the app landed, not at the target.
    func testAClampedParkIsAlignedWhereTheAppLanded() {
        let journal = Journal()
        let screen = Screen()
        let ids = [code: UInt32(8)]
        let apps = Apps([code: frame(904)], ids: ids, screen: screen, journal: journal)
        apps.clamps = [code: frame(1780)]
        let mover = Mover(ids, screen: screen, journal: journal)
        let reconciler = make(apps, mover)
        let report = reconciler.reconcile(
            frames: [:], parked: [code: ParkedTarget(frame: frame(1799), edge: .right, display: display)],
            focused: nil, currentlyFocused: nil, windowServerFirst: [code]
        )
        XCTAssertEqual(report.parked, [code])
        XCTAssertEqual(journal.lines, ["commit 8@1799", "write 4295:8@1799", "commit 8@1780"])
        XCTAssertEqual(screen[8], apps.believes(code))
        XCTAssertTrue(reconciler.windowServerPending.isEmpty)
    }

    /// Without the transport (config off, missing symbols, failed probe)
    /// nothing is aligned: the Accessibility-only path is unchanged.
    func testNothingIsAlignedWithoutTheTransport() {
        let journal = Journal()
        let screen = Screen()
        let ids = [tern: UInt32(6)]
        let apps = Apps([tern: frame(904)], ids: ids, screen: screen, journal: journal)
        let mover = Mover(ids, screen: screen, journal: journal)
        let reconciler = make(apps, mover)
        reconciler.windowServerEnabled = false
        reconciler.reconcile(frames: [tern: frame(8)], focused: nil, currentlyFocused: nil, windowServerFirst: [tern])
        XCTAssertEqual(journal.lines, ["write 57880:6@8"])
        XCTAssertTrue(reconciler.alignWindowServer(to: [tern: frame(8)]).isEmpty)
        XCTAssertTrue(mover.transactions.isEmpty)
    }

    /// The render repair's tool: a window the app reports at its target
    /// while the WindowServer draws it 1832 pt away (Code in the log). An
    /// Accessibility nudge cannot move it; one SkyLight transaction can, and
    /// it leaves nothing pending (the app already holds that frame). Gio's
    /// own windows are never moved.
    func testANudgeCannotMoveADesyncedWindowAndTheWindowServerRepairCan() {
        let journal = Journal()
        let screen = Screen()
        let own = WindowID(pid: 1, elementID: 1)
        let ids = [code: UInt32(8), own: UInt32(1)]
        let apps = Apps([code: frame(904), own: frame(8)], ids: ids, screen: screen, journal: journal)
        screen[8] = frame(-928)
        let mover = Mover(ids, screen: screen, journal: journal)
        let reconciler = make(apps, mover)
        reconciler.nudge(steps: [code: planNudge(target: frame(904), viewport: display)])
        XCTAssertEqual(screen[8], frame(-928), "a nudge moves the window by +1 and back")
        let moved = reconciler.alignWindowServer(to: [code: frame(904), own: frame(8)])
        XCTAssertEqual(moved, [code])
        XCTAssertEqual(mover.transactions, [[WindowServerMove(windowID: 8, frame: frame(904))]])
        XCTAssertEqual(screen[8], frame(904))
        XCTAssertTrue(reconciler.windowServerPending.isEmpty)
    }

    // MARK: Render repair (pure)

    func testADrawnMismatchIsRepairedThroughTheWindowServerFirst() {
        let drawn = RenderMismatch(id: code, ax: frame(904), ws: frame(-928))
        let missing = RenderMismatch(id: tern, ax: frame(8), ws: nil)
        let plan = planRenderRepairs([drawn, missing], windowServer: true)
        XCTAssertEqual(plan.windowServer, [code: frame(904)], "moved to the frame the app reports")
        XCTAssertEqual(plan.nudge, [tern], "a window not drawn at all needs the app to paint: nudge")
        let off = planRenderRepairs([drawn, missing], windowServer: false)
        XCTAssertTrue(off.windowServer.isEmpty)
        XCTAssertEqual(off.nudge, [code, tern], "sorted")
    }

    func testTheRepairLineNamesTheTransportAndTheResult() {
        XCTAssertEqual(
            renderRepairLine(id: code, app: "Code", fixed: true), "render repair id=4295:8 app=Code via=skylight fixed=true"
        )
    }
}
