import GioCore
import XCTest
@testable import GioSession

/// WS-02: the window server tells Gio a window appeared or went away even
/// when the app's Accessibility observer said nothing. An unregistered new
/// window gets its app scanned after a grace (the AX path usually registers
/// it first); a destroyed registered window gets the proof scan (rule 10).
final class WindowServerWatcherTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var owners: [UInt32: WindowServerWindowOwner] = [:]
    private var scans: [pid_t] = []
    private var proofs: [WindowID] = []
    private var frameChanges: [(WindowID, Bool, TimeInterval)] = []
    private var subscriptions: [[UInt32]] = []
    private var reorders: [WindowID] = []
    private var watcher: WindowServerWatcher!
    private let ownPID: pid_t = 1

    override func setUp() {
        scheduler = ManualScheduler()
        owners = [:]
        scans = []
        proofs = []
        frameChanges = []
        subscriptions = []
        reorders = []
        let scheduler = scheduler!
        watcher = WindowServerWatcher(
            context: .init(
                windowOwner: { [unowned self] in owners[$0] },
                ownPID: ownPID,
                allowsWindowWork: { true },
                scanApp: { [unowned self] in scans.append($0) },
                proveVanished: { [unowned self] in proofs.append($0) },
                frameChanged: { [unowned self] in frameChanges.append(($0, $1, $2)) },
                subscribe: { [unowned self] in subscriptions.append($0) },
                reordered: { [unowned self] in reorders.append($0) },
                now: { scheduler.now },
                log: { _, _ in }
            ),
            scheduler: scheduler
        )
    }

    func testUnregisteredWindowScansItsAppAfterTheGrace() {
        owners[7] = WindowServerWindowOwner(pid: 42, layer: 0)
        watcher.post(.created(7))
        scheduler.runPending()
        XCTAssertTrue(scans.isEmpty, "the AX path gets its chance first")
        scheduler.advance(by: WindowServerWatcher.arrivalGrace)
        XCTAssertEqual(scans, [42])
    }

    func testWindowRegisteredDuringTheGraceIsNotScanned() {
        owners[7] = WindowServerWindowOwner(pid: 42, layer: 0)
        watcher.post(.created(7))
        scheduler.runPending()
        watcher.noteRegistered(WindowID(pid: 42, elementID: 3), number: 7)
        scheduler.advance(by: WindowServerWatcher.arrivalGrace)
        XCTAssertTrue(scans.isEmpty)
    }

    /// One app opening several windows at once costs one scan.
    func testWindowsOfOneAppShareOneScan() {
        owners[7] = WindowServerWindowOwner(pid: 42, layer: 0)
        owners[8] = WindowServerWindowOwner(pid: 42, layer: 0)
        owners[9] = WindowServerWindowOwner(pid: 43, layer: 0)
        watcher.post(.created(7))
        watcher.post(.created(8))
        watcher.post(.created(9))
        scheduler.runPending()
        scheduler.advance(by: WindowServerWatcher.arrivalGrace)
        XCTAssertEqual(scans, [42, 43])
    }

    func testDestroyedRegisteredWindowAsksForTheProofScan() {
        let id = WindowID(pid: 42, elementID: 3)
        watcher.noteRegistered(id, number: 7)
        watcher.post(.destroyed(7))
        scheduler.runPending()
        XCTAssertEqual(proofs, [id])
    }

    func testForgottenWindowNoLongerMatchesItsNumber() {
        let id = WindowID(pid: 42, elementID: 3)
        watcher.noteRegistered(id, number: 7)
        watcher.forget(id)
        watcher.post(.destroyed(7))
        scheduler.runPending()
        XCTAssertTrue(proofs.isEmpty)
    }

    func testMenusAndGiosOwnWindowsNeverScan() {
        owners[7] = WindowServerWindowOwner(pid: 42, layer: 101)
        owners[8] = WindowServerWindowOwner(pid: ownPID, layer: 0)
        watcher.post(.created(7))
        watcher.post(.created(8))
        scheduler.runPending()
        scheduler.advance(by: WindowServerWatcher.arrivalGrace)
        XCTAssertTrue(scans.isEmpty)
    }

    // MARK: WS-03 frame notices

    /// The window server only reports a window's moves once it is asked to:
    /// every registration and removal re-sends the full list, once per turn.
    func testRegisteredNumbersAreSubscribedOncePerTurn() {
        watcher.noteRegistered(WindowID(pid: 42, elementID: 3), number: 9)
        watcher.noteRegistered(WindowID(pid: 42, elementID: 4), number: 7)
        scheduler.runPending()
        XCTAssertEqual(subscriptions, [[7, 9]])
        watcher.forget(WindowID(pid: 42, elementID: 3))
        scheduler.runPending()
        XCTAssertEqual(subscriptions, [[7, 9], [7]])
    }

    /// A burst of notices for one window is one check after the grace, with
    /// the first notice's time (the AX event that covers it may come later).
    func testFrameNoticesOfOneWindowCoalesceIntoOneCheck() {
        let id = WindowID(pid: 42, elementID: 3)
        watcher.noteRegistered(id, number: 7)
        scheduler.advance(by: 1)
        watcher.post(.moved(7))
        scheduler.runPending()
        scheduler.advance(by: 0.05)
        watcher.post(.resized(7))
        scheduler.runPending()
        XCTAssertTrue(frameChanges.isEmpty, "the AX path gets its chance first")
        scheduler.advance(by: WindowServerWatcher.frameGrace)
        XCTAssertEqual(frameChanges.count, 1)
        XCTAssertEqual(frameChanges.first?.0, id)
        XCTAssertEqual(frameChanges.first?.1, true, "a resize in the burst counts")
        XCTAssertEqual(frameChanges.first?.2, 1)
    }

    func testFrameNoticeOfAnUnknownWindowDoesNothing() {
        watcher.post(.moved(7))
        scheduler.runPending()
        scheduler.advance(by: WindowServerWatcher.frameGrace)
        XCTAssertTrue(frameChanges.isEmpty)
    }

    /// NF-13: a registered window moving in the stack is passed on at once
    /// (the ring re-orders above it); unknown windows are not.
    func testOrderChangeOfARegisteredWindowIsPassedOnAtOnce() {
        let id = WindowID(pid: 42, elementID: 3)
        watcher.noteRegistered(id, number: 7)
        watcher.post(.orderChanged(7))
        watcher.post(.orderChanged(8))
        scheduler.runPending()
        XCTAssertEqual(reorders, [id])
    }

    /// Diagnostics: what the notices did this session.
    func testCountsNoticesRescueScansAndNumberedWindows() {
        owners[7] = WindowServerWindowOwner(pid: 42, layer: 0)
        watcher.noteRegistered(WindowID(pid: 43, elementID: 1), number: 9)
        watcher.post(.created(7))
        watcher.post(.moved(9))
        scheduler.runPending()
        scheduler.advance(by: WindowServerWatcher.arrivalGrace)
        XCTAssertEqual(watcher.noticeCount, 2)
        XCTAssertEqual(watcher.rescueScanCount, 1)
        XCTAssertEqual(watcher.numberedWindowCount, 1)
    }
}
