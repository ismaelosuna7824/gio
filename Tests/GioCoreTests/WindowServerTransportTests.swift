import XCTest
@testable import GioCore

/// PF-L: hidden and revealed windows move through the WindowServer
/// (SkyLight) first, in one transaction, and Accessibility follows as the
/// authoritative write; without the transport everything stays on AX.
final class WindowServerTransportTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private let visibleFrame = CGRect(x: 100, y: 8, width: 700, height: 984)
    private var parkedFrame: CGRect { CGRect(x: 1799, y: 8, width: 700, height: 984) }
    private var parked: ParkedTarget { ParkedTarget(frame: parkedFrame, edge: .right, display: display) }

    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    // MARK: Status

    func testTheConfigTurnsItOff() {
        let status = windowServerTransportStatus(enabled: false, missingSymbols: [])
        XCTAssertFalse(status.available)
        XCTAssertEqual(status.logLine, "skylight available=false reason=config-off")
    }

    func testMissingSymbolsDisableItAndAreNamed() {
        let status = windowServerTransportStatus(
            enabled: true, missingSymbols: ["SLSTransactionCreate", "_AXUIElementGetWindow"]
        )
        XCTAssertFalse(status.available)
        XCTAssertEqual(status.reason, "missing-symbols:SLSTransactionCreate,_AXUIElementGetWindow")
    }

    func testResolvedSymbolsMakeItAvailable() {
        let status = windowServerTransportStatus(enabled: true, missingSymbols: [])
        XCTAssertTrue(status.available)
        XCTAssertEqual(status.logLine, "skylight available=true reason=symbols-resolved")
    }

    func testTheStatusIsLoggedOnceAndAgainOnlyWhenItChanges() {
        var gate = WindowServerStatusLogGate()
        let on = windowServerTransportStatus(enabled: true, missingSymbols: [])
        let off = windowServerTransportStatus(enabled: false, missingSymbols: [])
        XCTAssertEqual(gate.line(for: on), "skylight available=true reason=symbols-resolved")
        XCTAssertNil(gate.line(for: on))
        XCTAssertEqual(gate.line(for: off), "skylight available=false reason=config-off")
        XCTAssertNil(gate.line(for: off))
    }

    // MARK: Which windows go first (pure)

    func testOnlyParksAndRevealsGoThroughTheWindowServer() {
        let hiddenCorner = CGRect(x: 1799, y: -983, width: 700, height: 984)
        let first = planWindowServerFirst(
            visible: [
                id(1): visibleFrame, // reveal: parked now
                id(2): visibleFrame.offsetBy(dx: 900, dy: 0), // visible to visible
                id(3): visibleFrame, // unknown current frame
            ],
            parked: [
                id(4): parked, // park: on screen now
                id(5): parked, // hidden to hidden
            ],
            current: [
                id(1): parkedFrame,
                id(2): visibleFrame,
                id(4): visibleFrame,
                id(5): hiddenCorner,
            ],
            displays: [display], ownPID: 1
        )
        XCTAssertEqual(first, [id(1), id(4)])
    }

    func testGiosOwnWindowsNeverGoThroughTheWindowServer() {
        let first = planWindowServerFirst(
            visible: [id(1, pid: 7): visibleFrame], parked: [id(2, pid: 7): parked],
            current: [id(1, pid: 7): parkedFrame, id(2, pid: 7): visibleFrame],
            displays: [display], ownPID: 7
        )
        XCTAssertTrue(first.isEmpty)
    }

    // MARK: Reconciler

    /// One ordered journal for the WindowServer and Accessibility.
    final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ line: String) { lock.withLock { entries.append(line) } }
        var lines: [String] { lock.withLock { entries } }
    }

    final class Mover: WindowServerMover, @unchecked Sendable {
        let journal: Journal
        var ids: [WindowID: UInt32]
        var accepts = true
        private(set) var transactions: [[WindowServerMove]] = []

        init(_ ids: [WindowID: UInt32], journal: Journal) {
            self.ids = ids
            self.journal = journal
        }

        func windowServerID(of id: WindowID) -> UInt32? { ids[id] }

        func commit(_ moves: [WindowServerMove]) -> Bool {
            guard accepts else { return false }
            transactions.append(moves)
            journal.append("commit " + moves.map { "\($0.windowID)" }.joined(separator: ","))
            return true
        }
    }

    /// The app reports `reported` (what it believes) and records writes.
    final class Actuator: WindowActuator, @unchecked Sendable {
        let journal: Journal
        private let lock = NSLock()
        var reported: [WindowID: CGRect]
        var failing: Set<WindowID> = []
        private(set) var writes: [(WindowID, CGRect, CGRect)] = []

        init(_ reported: [WindowID: CGRect], journal: Journal) {
            self.reported = reported
            self.journal = journal
        }

        func frame(of id: WindowID) throws -> CGRect? { lock.withLock { reported[id] } }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            try setFrame(frame, from: .zero, for: id, verify: true)
        }

        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            if failing.contains(id) {
                throw NSError(domain: "mock", code: 1)
            }
            journal.append("write \(id.pid):\(id.elementID)")
            lock.withLock {
                writes.append((id, frame, current))
                reported[id] = frame
            }
        }

        func focus(id: WindowID) throws {}
    }

    private func make(
        _ actuator: Actuator, _ mover: Mover?, enabled: Bool = true
    ) -> WindowReconciler<Actuator> {
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial, windowServer: mover, ownPID: 1)
        reconciler.windowServerEnabled = enabled
        return reconciler
    }

    func testParksAndRevealsCommitOneTransactionBeforeTheirAXWrites() {
        let journal = Journal()
        let actuator = Actuator([id(1): parkedFrame, id(2): visibleFrame], journal: journal)
        let mover = Mover([id(1): 101, id(2): 102], journal: journal)
        let reconciler = make(actuator, mover)
        let report = reconciler.reconcile(
            frames: [id(1): visibleFrame], parked: [id(2): parked], focused: nil, currentlyFocused: nil,
            windowServerFirst: [id(1), id(2)]
        )
        XCTAssertEqual(journal.lines, ["commit 101,102", "write 10:2", "write 10:1"])
        XCTAssertEqual(mover.transactions.first, [
            WindowServerMove(windowID: 101, frame: visibleFrame), WindowServerMove(windowID: 102, frame: parkedFrame),
        ])
        XCTAssertEqual(report.applied, [id(1)])
        XCTAssertEqual(report.parked, [id(2)])
    }

    func testTheAXFollowUpIsWrittenEvenWhenTheAppAlreadyReportsTheTarget() {
        let journal = Journal()
        // The app already reports the parked frame (it learned the move).
        let actuator = Actuator([id(2): parkedFrame], journal: journal)
        let reconciler = make(actuator, Mover([id(2): 102], journal: journal))
        let report = reconciler.reconcile(
            frames: [:], parked: [id(2): parked], focused: nil, currentlyFocused: nil, windowServerFirst: [id(2)]
        )
        XCTAssertEqual(journal.lines, ["commit 102", "write 10:2"])
        XCTAssertEqual(actuator.writes.first?.1, parkedFrame)
        XCTAssertEqual(report.parked, [id(2)])
        XCTAssertTrue(reconciler.windowServerPending.isEmpty)
    }

    func testAWindowWithoutAWindowServerIDKeepsTheAXPathOnly() {
        let journal = Journal()
        let actuator = Actuator([id(1): parkedFrame], journal: journal)
        let reconciler = make(actuator, Mover([:], journal: journal))
        reconciler.reconcile(
            frames: [id(1): visibleFrame], focused: nil, currentlyFocused: nil, windowServerFirst: [id(1)]
        )
        XCTAssertEqual(journal.lines, ["write 10:1"])
    }

    func testWithTheTransportOffOrMissingEverythingStaysOnAX() {
        for mover in [Mover([id(1): 101], journal: Journal()), nil] {
            let journal = Journal()
            let actuator = Actuator([id(1): parkedFrame], journal: journal)
            let reconciler = make(actuator, mover, enabled: mover == nil)
            reconciler.reconcile(
                frames: [id(1): visibleFrame], focused: nil, currentlyFocused: nil, windowServerFirst: [id(1)]
            )
            XCTAssertEqual(journal.lines, ["write 10:1"])
            XCTAssertTrue(mover?.transactions.isEmpty ?? true)
        }
    }

    func testARefusedTransactionLeavesNothingPending() {
        let journal = Journal()
        let actuator = Actuator([id(1): parkedFrame], journal: journal)
        let mover = Mover([id(1): 101], journal: journal)
        mover.accepts = false
        let reconciler = make(actuator, mover)
        reconciler.reconcile(
            frames: [id(1): visibleFrame], focused: nil, currentlyFocused: nil, windowServerFirst: [id(1)]
        )
        XCTAssertEqual(journal.lines, ["write 10:1"])
        XCTAssertTrue(reconciler.windowServerPending.isEmpty)
    }

    func testAFailedFollowUpStaysPendingAndIsNeverSkippedAsTrusted() {
        let journal = Journal()
        let actuator = Actuator([id(1): parkedFrame], journal: journal)
        actuator.failing = [id(1)]
        let reconciler = make(actuator, Mover([id(1): 101], journal: journal))
        reconciler.reconcile(
            frames: [id(1): visibleFrame], focused: nil, currentlyFocused: nil, windowServerFirst: [id(1)]
        )
        XCTAssertEqual(reconciler.windowServerPending, [id(1): visibleFrame])
        actuator.failing = []
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: visibleFrame)
        let report = reconciler.reconcile(
            frames: [id(1): visibleFrame], focused: nil, currentlyFocused: nil, trusted: trusted
        )
        XCTAssertEqual(report.applied, [id(1)])
        XCTAssertEqual(report.skippedReads, 0)
        XCTAssertTrue(reconciler.windowServerPending.isEmpty)
    }

    func testGiosOwnPidIsNeverMovedThroughTheWindowServer() {
        let journal = Journal()
        let own = WindowID(pid: 1, elementID: 1)
        let actuator = Actuator([own: parkedFrame], journal: journal)
        let reconciler = make(actuator, Mover([own: 101], journal: journal))
        reconciler.reconcile(frames: [own: visibleFrame], focused: nil, currentlyFocused: nil, windowServerFirst: [own])
        XCTAssertEqual(journal.lines, ["write 1:1"])
    }

    func testADispatchedPassMovesThroughTheWindowServerBeforeItsLanes() {
        let journal = Journal()
        let actuator = Actuator([id(1): parkedFrame], journal: journal)
        let reconciler = make(actuator, Mover([id(1): 101], journal: journal))
        let pass = reconciler.dispatch(
            frames: [id(1): visibleFrame], focused: nil, currentlyFocused: nil, windowServerFirst: [id(1)]
        )
        let report = reconciler.collect(pass)
        XCTAssertEqual(journal.lines, ["commit 101", "write 10:1"])
        XCTAssertEqual(report.applied, [id(1)])
        XCTAssertTrue(reconciler.windowServerPending.isEmpty)
    }

    // MARK: Pre-positions

    func testSameSizePrepositionsGoThroughTheWindowServerAloneAndStayPending() {
        let journal = Journal()
        let hidden = CGRect(x: 1799, y: -983, width: 700, height: 984)
        let below = CGRect(x: 100, y: -983, width: 700, height: 984)
        let resized = CGRect(x: 900, y: -583, width: 500, height: 584)
        let actuator = Actuator([:], journal: journal)
        let reconciler = make(actuator, Mover([id(1): 101, id(2): 102], journal: journal))
        let written = reconciler.preposition(
            frames: [id(1): below, id(2): resized], from: [id(1): hidden, id(2): hidden]
        )
        XCTAssertEqual(written, [id(1), id(2)])
        // The resized one still needs Accessibility (SkyLight moves, never resizes).
        XCTAssertEqual(journal.lines, ["commit 101", "write 10:2"])
        XCTAssertEqual(reconciler.windowServerPending, [id(1): below])
    }

    func testSyncWritesEveryPendingWindowWhereTheWindowServerPutIt() {
        let journal = Journal()
        let hidden = CGRect(x: 1799, y: -983, width: 700, height: 984)
        let below = CGRect(x: 100, y: -983, width: 700, height: 984)
        let actuator = Actuator([id(1): hidden], journal: journal)
        let reconciler = make(actuator, Mover([id(1): 101], journal: journal))
        reconciler.preposition(frames: [id(1): below], from: [id(1): hidden])
        reconciler.syncWindowServerMoves()
        XCTAssertEqual(journal.lines, ["commit 101", "write 10:1"])
        XCTAssertEqual(actuator.writes.last?.1, below)
        XCTAssertTrue(reconciler.windowServerPending.isEmpty)
    }
}
