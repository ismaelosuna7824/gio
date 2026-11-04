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
    private var watcher: WindowServerWatcher!
    private let ownPID: pid_t = 1

    override func setUp() {
        scheduler = ManualScheduler()
        owners = [:]
        scans = []
        proofs = []
        watcher = WindowServerWatcher(
            context: .init(
                windowOwner: { [unowned self] in owners[$0] },
                ownPID: ownPID,
                allowsWindowWork: { true },
                scanApp: { [unowned self] in scans.append($0) },
                proveVanished: { [unowned self] in proofs.append($0) },
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
}
