import Foundation
import GioCore
import GioMacOS

/// SB-01 `[hooks]`: after every reflow and IPC command the host calls
/// `update()`; the notifier diffs the bar state (`diffWorkspaceBar`) and runs
/// `on-workspace-change` at once and `on-windows-change` ~100 ms later
/// (coalesced). Each hook has one run in flight (`HookFlight`); changes
/// meanwhile fold into one rerun that reads the latest state. The runner
/// spawns off the session queue and its result hops back onto it. Session
/// queue only. Logs the hook's name, duration and status, never the command.
public final class BarHookNotifier: @unchecked Sendable {
    public static let windowsDelay: TimeInterval = 0.1
    public static let timeout: TimeInterval = 5

    public struct Context {
        public var hooks: () -> HooksSectionConfig
        public var state: () -> WorkspaceBarState
        /// The environment hooks inherit (the app's).
        public var environment: () -> [String: String]
        public var home: String
        public var log: (LogLevel, String) -> Void

        public init(
            hooks: @escaping () -> HooksSectionConfig, state: @escaping () -> WorkspaceBarState,
            environment: @escaping () -> [String: String], home: String,
            log: @escaping (LogLevel, String) -> Void
        ) {
            self.hooks = hooks
            self.state = state
            self.environment = environment
            self.home = home
            self.log = log
        }
    }

    private enum Hook: String {
        case workspace = "on-workspace-change"
        case windows = "on-windows-change"
    }

    private let context: Context
    private let runner: HookRunner
    private let scheduler: SessionScheduler
    private var last: WorkspaceBarState?
    /// The focused workspace before the last focus change (`GIO_PREV_WORKSPACE`).
    private var previousWorkspace: Int?
    private var flights: [Hook: HookFlight] = [:]
    private var windowsScheduled = false

    public init(context: Context, runner: HookRunner, scheduler: SessionScheduler) {
        self.context = context
        self.runner = runner
        self.scheduler = scheduler
    }

    /// Cheap no-op without hooks: no state is built.
    public func update() {
        scheduler.assertOnQueue()
        let hooks = context.hooks()
        guard !hooks.isEmpty else {
            last = nil
            previousWorkspace = nil
            return
        }
        let state = context.state()
        let change = diffWorkspaceBar(previous: last, current: state)
        if let last, last.focusedDisplay != state.focusedDisplay || last.focusedWorkspace != state.focusedWorkspace {
            previousWorkspace = last.focusedWorkspace
        }
        last = state
        if change.workspace, hooks.onWorkspaceChange != nil {
            request(.workspace)
        }
        if change.windows, hooks.onWindowsChange != nil, !windowsScheduled {
            windowsScheduled = true
            scheduler.asyncAfter(Self.windowsDelay) { [weak self] in
                guard let self else {
                    return
                }
                windowsScheduled = false
                request(.windows)
            }
        }
    }

    private func request(_ hook: Hook) {
        if flights[hook, default: HookFlight()].request() {
            launch(hook)
        }
    }

    private func launch(_ hook: Hook) {
        let hooks = context.hooks()
        guard let command = hook == .workspace ? hooks.onWorkspaceChange : hooks.onWindowsChange, let state = last else {
            // Turned off while queued: free the slot.
            flights[hook] = HookFlight()
            return
        }
        let environment = hookEnvironment(
            base: context.environment(), state: state, previousWorkspace: previousWorkspace, home: context.home
        )
        let request = HookRunRequest(name: hook.rawValue, command: command, environment: environment, timeout: Self.timeout)
        runner.run(request) { [weak self] result in
            self?.scheduler.async { [weak self] in
                self?.finished(hook, result)
            }
        }
    }

    private func finished(_ hook: Hook, _ result: HookRunResult) {
        let status: String
        switch result.status {
        case .exited(let code): status = String(code)
        case .timedOut: status = "timeout"
        case .launchFailed: status = "launch-failed"
        }
        let level: LogLevel = result.status == .exited(0) ? .debug : .warn
        context.log(level, "hook ran name=\(hook.rawValue) ms=\(result.milliseconds) status=\(status)")
        if flights[hook, default: HookFlight()].finish() {
            launch(hook)
        }
    }
}
