import Foundation
import GioCore
import GioMacOS
@testable import GioSession
import XCTest

/// SB-01: `[hooks]` run off the session queue, one at a time per hook, the
/// latest state coalesced; `on-windows-change` waits ~100 ms.
final class BarHookNotifierTests: XCTestCase {
    private final class FakeRunner: HookRunner, @unchecked Sendable {
        var requests: [HookRunRequest] = []
        var completions: [@Sendable (HookRunResult) -> Void] = []

        func run(_ request: HookRunRequest, completion: @escaping @Sendable (HookRunResult) -> Void) {
            requests.append(request)
            completions.append(completion)
        }

        func finish(_ index: Int, _ result: HookRunResult = HookRunResult(status: .exited(0), milliseconds: 12)) {
            completions[index](result)
        }

        func names() -> [String] {
            requests.map(\.name)
        }
    }

    private var scheduler: ManualScheduler!
    private var runner: FakeRunner!
    private var hooks = HooksSectionConfig(
        onWorkspaceChange: "sketchybar --trigger gio_workspace_change",
        onWindowsChange: "sketchybar --trigger gio_windows_change"
    )
    private var state = WorkspaceBarState(focusedDisplay: 1, focusedWorkspace: 1, focusedName: nil, workspaces: [])
    private var stateReads = 0
    private var logs: [(LogLevel, String)] = []
    private var notifier: BarHookNotifier!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        runner = FakeRunner()
        notifier = BarHookNotifier(
            context: .init(
                hooks: { [unowned self] in hooks },
                state: { [unowned self] in
                    stateReads += 1
                    return state
                },
                environment: { ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"] },
                home: "/Users/me",
                log: { [unowned self] in logs.append(($0, $1)) }
            ),
            runner: runner, scheduler: scheduler
        )
    }

    private func entry(_ index: Int, windows: Int = 0, apps: [String] = [], focused: Bool = false) -> WorkspaceBarEntry {
        WorkspaceBarEntry(display: 1, index: index, windows: windows, apps: apps, focused: focused, visible: focused)
    }

    private func focus(_ workspace: Int, windows: Int = 0) {
        state = WorkspaceBarState(
            focusedDisplay: 1, focusedWorkspace: workspace, focusedName: nil,
            workspaces: (1...3).map { entry($0, windows: $0 == 1 ? windows : 0, focused: $0 == workspace) }
        )
    }

    func testNothingIsBuiltWithoutHooks() {
        hooks = HooksSectionConfig()
        notifier.update()
        scheduler.advance(by: 1)
        XCTAssertEqual(stateReads, 0)
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testStartupFiresBothHooksOnce() {
        focus(1)
        notifier.update()
        XCTAssertEqual(runner.names(), ["on-workspace-change"], "the workspace hook runs at once")
        scheduler.advance(by: 0.05)
        XCTAssertEqual(runner.names(), ["on-workspace-change"])
        scheduler.advance(by: 0.06)
        XCTAssertEqual(runner.names(), ["on-workspace-change", "on-windows-change"], "the windows hook ~100 ms later")
        let request = runner.requests[0]
        XCTAssertEqual(request.command, "sketchybar --trigger gio_workspace_change")
        XCTAssertEqual(request.timeout, 5)
        XCTAssertEqual(request.environment["GIO_FOCUSED_WORKSPACE"], "1")
        XCTAssertEqual(request.environment["GIO_PREV_WORKSPACE"], "")
        XCTAssertEqual(request.environment["GIO_DISPLAY"], "1")
        XCTAssertEqual(request.environment["HOME"], "/Users/me")
        notifier.update()
        scheduler.advance(by: 1)
        XCTAssertEqual(runner.requests.count, 2, "nothing changed")
    }

    func testAWorkspaceChangeWhileRunningRunsOnceMoreWithTheLatestState() {
        hooks.onWindowsChange = nil
        focus(1)
        notifier.update()
        focus(2)
        notifier.update()
        focus(3)
        notifier.update()
        XCTAssertEqual(runner.requests.count, 1, "one in flight")
        runner.finish(0)
        XCTAssertEqual(runner.requests.count, 1, "the result hops onto the session queue")
        scheduler.runPending()
        XCTAssertEqual(runner.requests.count, 2)
        XCTAssertEqual(runner.requests[1].environment["GIO_FOCUSED_WORKSPACE"], "3")
        XCTAssertEqual(runner.requests[1].environment["GIO_PREV_WORKSPACE"], "2")
        runner.finish(1)
        scheduler.runPending()
        XCTAssertEqual(runner.requests.count, 2, "no change left")
    }

    func testWindowChangesCoalesce() {
        hooks.onWorkspaceChange = nil
        focus(1)
        notifier.update()
        scheduler.advance(by: 0.2)
        runner.finish(0)
        scheduler.runPending()
        XCTAssertEqual(runner.requests.count, 1)
        focus(1, windows: 1)
        notifier.update()
        scheduler.advance(by: 0.03)
        focus(1, windows: 2)
        notifier.update()
        scheduler.advance(by: 0.03)
        focus(1, windows: 3)
        notifier.update()
        scheduler.advance(by: 0.2)
        XCTAssertEqual(runner.names(), ["on-windows-change", "on-windows-change"])
        XCTAssertEqual(runner.requests[1].command, "sketchybar --trigger gio_windows_change")
    }

    func testRunsAreLoggedWithoutTheCommand() {
        hooks.onWindowsChange = nil
        focus(1)
        notifier.update()
        runner.finish(0, HookRunResult(status: .exited(0), milliseconds: 12))
        scheduler.runPending()
        focus(2)
        notifier.update()
        runner.finish(1, HookRunResult(status: .timedOut, milliseconds: 5000))
        scheduler.runPending()
        focus(3)
        notifier.update()
        runner.finish(2, HookRunResult(status: .exited(127), milliseconds: 3))
        scheduler.runPending()
        focus(1)
        notifier.update()
        runner.finish(3, HookRunResult(status: .launchFailed, milliseconds: 0))
        scheduler.runPending()
        XCTAssertEqual(logs.map(\.0), [.debug, .warn, .warn, .warn])
        XCTAssertEqual(logs.map(\.1), [
            "hook ran name=on-workspace-change ms=12 status=0",
            "hook ran name=on-workspace-change ms=5000 status=timeout",
            "hook ran name=on-workspace-change ms=3 status=127",
            "hook ran name=on-workspace-change ms=0 status=launch-failed",
        ])
    }

    func testTurningHooksOffAndOnStartsInSyncAgain() {
        hooks.onWindowsChange = nil
        focus(1)
        notifier.update()
        runner.finish(0)
        scheduler.runPending()
        let enabled = hooks
        hooks = HooksSectionConfig()
        notifier.update()
        hooks = enabled
        notifier.update()
        XCTAssertEqual(runner.requests.count, 2, "re-enabled hooks fire for the current state")
    }
}
