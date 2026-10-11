import XCTest
@testable import GioCore

/// PF-M: during an AX motion, flights that hide or reveal a window move it
/// through the WindowServer, one transaction per tick, with no Accessibility
/// write until the final pass; a runtime probe turns the transport off when
/// the WindowServer ignores the moves.
final class WindowServerMotionTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private let visible = CGRect(x: 100, y: 8, width: 700, height: 984)
    private var parkedEdge: CGRect { CGRect(x: 1799, y: 8, width: 700, height: 984) }

    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private func flight(_ window: WindowID, from: CGRect, to: CGRect) -> WindowAnimation {
        WindowAnimation(id: window, from: from, to: to, duration: 1, easing: .linear)
    }

    // MARK: Which flights (pure)

    func testHideAndRevealFlightsGoThroughTheWindowServerAndTheRestStaysOnAX() {
        let below = slideDownFrame(visible, display: display)
        var grows = flight(id(6), from: parkedEdge, to: CGRect(x: 100, y: 8, width: 900, height: 984))
        grows.sizeSchedule = .fromStart
        let planned = planMotionTransports(
            [
                flight(id(1), from: parkedEdge, to: visible), // reveal from the edge
                flight(id(2), from: visible, to: parkedEdge), // park to the edge
                flight(id(3), from: visible, to: below), // workspace drop
                flight(id(4), from: below, to: visible), // workspace rise
                flight(id(5), from: visible, to: visible.offsetBy(dx: 400, dy: 0)), // scroll in view
                grows, // reveal whose size follows the flight
                flight(id(7), from: parkedEdge, to: CGRect(x: 100, y: 8, width: 500, height: 984)), // shrinks
                flight(id(8), from: parkedEdge, to: CGRect(x: 100, y: 8, width: 900, height: 984)), // FI-03 grow
                flight(id(9, pid: 7), from: parkedEdge, to: visible), // Gio's own
            ],
            viewports: [display], enabled: true, ownPID: 7
        )
        XCTAssertEqual(planned.filter { $0.transport == .windowServer }.map(\.id), [id(1), id(2), id(3), id(4), id(8)])
    }

    func testWithoutTheTransportEveryFlightStaysOnAX() {
        let planned = planMotionTransports(
            [flight(id(1), from: parkedEdge, to: visible)], viewports: [display], enabled: false, ownPID: 7
        )
        XCTAssertEqual(planned.map(\.transport), [.accessibility])
    }

    func testARetargetedSpringKeepsItsTransport() {
        var animation = flight(id(1), from: parkedEdge, to: visible)
        animation.transport = .windowServer
        XCTAssertEqual(animation.springing(.niri).transport, .windowServer)
    }

    // MARK: Player

    private final class Clock: @unchecked Sendable {
        var now: TimeInterval = 0
    }

    private final class Sink: MotionFrameSink {
        var accepted: [(pid: pid_t, writes: [MotionWrite])] = []
        var serverBatches: [[MotionWrite]] = []
        var refusing: Set<WindowID> = []

        func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool {
            accepted.append((pid, writes))
            return true
        }

        func submitWindowServerMotion(_ writes: [MotionWrite]) -> Set<WindowID> {
            serverBatches.append(writes)
            return Set(writes.map(\.id)).subtracting(refusing)
        }

        func takeMotionStats() -> [pid_t: MotionWriteStats] { [:] }
    }

    func testWindowServerFlightsAreOneBatchPerTickWithNoAXWrite() {
        let clock = Clock(), sink = Sink()
        let player = MotionPlayer(sink: sink, clock: { clock.now })
        var reveal = flight(id(1), from: parkedEdge, to: visible)
        reveal.transport = .windowServer
        var park = flight(id(2, pid: 11), from: visible, to: parkedEdge)
        park.transport = .windowServer
        let scroll = flight(id(3), from: visible, to: visible.offsetBy(dx: 400, dy: 0))
        player.start([reveal, park, scroll])
        clock.now = 0.5
        let tick = player.tick()
        XCTAssertEqual(sink.serverBatches.count, 1)
        XCTAssertEqual(Set(sink.serverBatches[0].map(\.id)), [id(1), id(2, pid: 11)])
        XCTAssertEqual(sink.accepted.flatMap(\.writes).map(\.id), [id(3)])
        XCTAssertEqual(tick.sampled.count, 3)
    }

    func testRefusedWindowServerWritesFallBackToAXInTheSameTick() {
        let clock = Clock(), sink = Sink()
        sink.refusing = [id(1)]
        let player = MotionPlayer(sink: sink, clock: { clock.now })
        var reveal = flight(id(1), from: parkedEdge, to: visible)
        reveal.transport = .windowServer
        player.start([reveal])
        clock.now = 0.5
        _ = player.tick()
        XCTAssertEqual(sink.accepted.map(\.pid), [10])
        XCTAssertEqual(sink.accepted.first?.writes.first?.from, parkedEdge)
        clock.now = 0.75
        _ = player.tick()
        // The next tick continues from the frame the AX write carried.
        XCTAssertEqual(sink.accepted.last?.writes.first?.from, sink.accepted.first?.writes.first?.to)
    }

    // MARK: Reconciler

    final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ line: String) { lock.withLock { entries.append(line) } }
        var lines: [String] { lock.withLock { entries } }
    }

    final class Mover: WindowServerMover, @unchecked Sendable {
        let journal: Journal
        var ids: [WindowID: UInt32]
        /// What the WindowServer reports: nil follows the moves.
        var drawn: [UInt32: CGRect]?
        private(set) var placed: [UInt32: CGRect] = [:]
        private(set) var observations = 0

        init(_ ids: [WindowID: UInt32], journal: Journal) {
            self.ids = ids
            self.journal = journal
        }

        func windowServerID(of id: WindowID) -> UInt32? { ids[id] }

        func commit(_ moves: [WindowServerMove]) -> Bool {
            journal.append("commit " + moves.map { "\($0.windowID)" }.joined(separator: ","))
            for move in moves {
                placed[move.windowID] = move.frame
            }
            return true
        }

        func frames(of windowIDs: [UInt32]) -> [UInt32: CGRect] {
            observations += 1
            let source = drawn ?? placed
            return source.filter { windowIDs.contains($0.key) }
        }
    }

    final class Actuator: WindowActuator, @unchecked Sendable {
        let journal: Journal
        private let lock = NSLock()
        var reported: [WindowID: CGRect]

        init(_ reported: [WindowID: CGRect], journal: Journal) {
            self.reported = reported
            self.journal = journal
        }

        func frame(of id: WindowID) throws -> CGRect? { lock.withLock { reported[id] } }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            try setFrame(frame, from: .zero, for: id, verify: true)
        }

        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            journal.append("write \(id.pid):\(id.elementID)")
            lock.withLock { reported[id] = frame }
        }

        func focus(id: WindowID) throws {}
    }

    private func make(_ actuator: Actuator, _ mover: Mover) -> WindowReconciler<Actuator> {
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial, windowServer: mover, ownPID: 1)
        reconciler.windowServerEnabled = true
        return reconciler
    }

    private func step(_ x: CGFloat, _ window: WindowID = WindowID(pid: 10, elementID: 1)) -> MotionWrite {
        let from = CGRect(x: 1799 - x + 50, y: 8, width: 700, height: 984)
        return MotionWrite(id: window, from: from, to: from.offsetBy(dx: -50, dy: 0))
    }

    func testMotionFramesAreOneTransactionAndTheFinalPassFollowsWithAX() {
        let journal = Journal()
        let actuator = Actuator([id(1): parkedEdge], journal: journal)
        let mover = Mover([id(1): 101], journal: journal)
        let reconciler = make(actuator, mover)
        XCTAssertEqual(reconciler.submitWindowServerMotion([step(50)]), [id(1)])
        XCTAssertEqual(reconciler.submitWindowServerMotion([MotionWrite(id: id(1), from: step(50).to, to: visible)]), [id(1)])
        XCTAssertEqual(journal.lines, ["commit 101", "commit 101"])
        XCTAssertEqual(reconciler.windowServerPending, [id(1): visible])
        // The app still believes the parked frame; the final pass tells it.
        reconciler.reconcile(frames: [id(1): visible], focused: nil, currentlyFocused: nil)
        XCTAssertEqual(journal.lines.last, "write 10:1")
        XCTAssertTrue(reconciler.windowServerPending.isEmpty)
    }

    func testNoTransportNoWindowServerMotion() {
        let journal = Journal()
        let reconciler = make(Actuator([:], journal: journal), Mover([id(1): 101], journal: journal))
        reconciler.windowServerEnabled = false
        XCTAssertEqual(reconciler.submitWindowServerMotion([step(50)]), [])
        XCTAssertTrue(journal.lines.isEmpty)
    }

    func testTheProbeVerifiesWhenTheWindowServerShowsAMove() {
        let journal = Journal()
        let mover = Mover([id(1): 101], journal: journal)
        let reconciler = make(Actuator([:], journal: journal), mover)
        _ = reconciler.submitWindowServerMotion([step(50)])
        XCTAssertEqual(reconciler.windowServerProbe, .unverified)
        _ = reconciler.submitWindowServerMotion([step(100)])
        XCTAssertEqual(reconciler.windowServerProbe, .verified)
        _ = reconciler.submitWindowServerMotion([step(150)])
        XCTAssertEqual(mover.observations, 1, "a verified transport is not observed again")
    }

    func testTheProbeFailsWhenTheWindowStaysPutAndMotionFallsBackToAX() {
        let journal = Journal()
        let mover = Mover([id(1): 101], journal: journal)
        mover.drawn = [101: step(50).from]
        let reconciler = make(Actuator([:], journal: journal), mover)
        var moved: Set<WindowID> = []
        for tick in 1...6 {
            moved = reconciler.submitWindowServerMotion([step(CGFloat(tick) * 50)])
            if moved.isEmpty {
                break
            }
        }
        XCTAssertEqual(reconciler.windowServerProbe, .failed)
        XCTAssertEqual(moved, [])
        XCTAssertEqual(journal.lines.filter { $0.hasPrefix("commit") }.count, WindowServerProbe.failureObservations)
        // Instant passes stop using it too.
        mover.ids[id(2)] = 102
        reconciler.reconcile(
            frames: [id(2): visible], focused: nil, currentlyFocused: nil, windowServerFirst: [id(2)]
        )
        XCTAssertFalse(journal.lines.contains("commit 102"))
    }

    // MARK: Probe (pure)

    func testAnObservationAwayFromBothTheStartAndTheMovesIsInconclusive() {
        var probe = WindowServerProbe()
        probe.moved(windowID: 9, from: CGRect(x: 0, y: 0, width: 10, height: 10), to: CGRect(x: 100, y: 0, width: 10, height: 10))
        XCTAssertEqual(probe.observationTargets(), [9])
        probe.observe([9: CGRect(x: 500, y: 500, width: 10, height: 10)])
        XCTAssertEqual(probe.state, .unverified)
        probe.observe([:])
        XCTAssertEqual(probe.state, .unverified)
        probe.observe([9: CGRect(x: 101, y: 1, width: 10, height: 10)])
        XCTAssertEqual(probe.state, .verified)
        XCTAssertTrue(probe.observationTargets().isEmpty)
    }

    func testStatusFollowsTheProbe() {
        XCTAssertEqual(
            windowServerTransportStatus(enabled: true, missingSymbols: [], probe: .failed).logLine,
            "skylight available=false reason=probe-failed"
        )
        XCTAssertEqual(
            windowServerTransportStatus(enabled: true, missingSymbols: [], probe: .verified).logLine,
            "skylight available=true reason=probe-verified"
        )
        XCTAssertEqual(
            windowServerTransportStatus(enabled: false, missingSymbols: [], probe: .failed).reason, "config-off"
        )
    }
}
