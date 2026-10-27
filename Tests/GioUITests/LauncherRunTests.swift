import Foundation
import GioCore
@testable import GioUI
import XCTest

/// An IPC runner held until the test releases it (any thread).
private final class HeldRunner: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let outcome: String
    private let lock = NSLock()
    private var _requests: [LauncherEntry] = []
    private var _ranOnMain = false

    init(outcome: String) {
        self.outcome = outcome
    }

    var requests: [LauncherEntry] { lock.withLock { _requests } }
    var ranOnMain: Bool { lock.withLock { _ranOnMain } }

    func run(_ entry: LauncherEntry) -> String {
        lock.withLock {
            _requests.append(entry)
            _ranOnMain = _ranOnMain || Thread.isMainThread
        }
        release.wait()
        return outcome
    }
}

/// PA-17c: a Gio command or workspace entry is an IPC round trip that waits
/// on the session queue; the launcher sends it off the main thread and
/// applies the outcome (status or dismiss) back on main.
@MainActor
final class LauncherRunTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testGioCommandReturnsBeforeTheReplyAndShowsItAfter() async {
        let runner = HeldRunner(outcome: "config reloaded")
        let model = LauncherViewModel(requestIPC: { runner.run($0) })
        var dismissals: [LauncherDismissReason] = []
        model.dismiss = { dismissals.append($0) }
        let entry = LauncherEntry.gioCommand(argv: ["reload"], label: "reload")

        model.run(entry)

        // Back on main while the request is still waiting for its reply.
        XCTAssertNil(model.status)
        await waitUntil { !runner.requests.isEmpty }
        XCTAssertEqual(runner.requests, [entry])
        XCTAssertFalse(runner.ranOnMain)
        XCTAssertNil(model.status)
        runner.release.signal()
        await waitUntil { model.status != nil }
        XCTAssertEqual(model.status, "config reloaded")
        XCTAssertTrue(dismissals.isEmpty)
    }

    func testWorkspaceSwitchDismissesOnceTheReplyLands() async {
        let runner = HeldRunner(outcome: "switched to Code")
        let model = LauncherViewModel(requestIPC: { runner.run($0) })
        var dismissals: [LauncherDismissReason] = []
        model.dismiss = { dismissals.append($0) }

        model.run(.workspace(index: 2, name: "Code", icon: nil, color: nil))

        XCTAssertTrue(dismissals.isEmpty)
        runner.release.signal()
        await waitUntil { !dismissals.isEmpty }
        XCTAssertEqual(dismissals, [.action])
        XCTAssertNil(model.status)
    }

    func testFailedWorkspaceSwitchShowsTheOutcome() async {
        let runner = HeldRunner(outcome: "no running Gio session")
        let model = LauncherViewModel(requestIPC: { runner.run($0) })
        var dismissals: [LauncherDismissReason] = []
        model.dismiss = { dismissals.append($0) }

        model.run(.workspace(index: 2, name: "Code", icon: nil, color: nil))
        runner.release.signal()
        await waitUntil { model.status != nil }

        XCTAssertEqual(model.status, "no running Gio session")
        XCTAssertTrue(dismissals.isEmpty)
    }
}
