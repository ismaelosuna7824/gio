import CoreGraphics
import Foundation

/// The live state commands act on. Owned by the session host (one-shot
/// callers, the IPC server in RW-17, the daemon later) — the dispatcher
/// never stores it. Environment facts the host fills in when known
/// (`permissionGranted`, `displayCount`, `configPath`); nil means unknown
/// and renders honestly instead of guessing.
public struct CommandSession {
    public var registry: WindowRegistry
    public var manager: WorkspaceManager
    public var config: GioConfig
    public var permissionGranted: Bool?
    public var displayCount: Int?
    public var recentErrors: [String]
    public var configPath: String?

    public init(
        registry: WindowRegistry = WindowRegistry(),
        manager: WorkspaceManager = WorkspaceManager(),
        config: GioConfig = defaultGioConfig(),
        permissionGranted: Bool? = nil,
        displayCount: Int? = nil,
        recentErrors: [String] = [],
        configPath: String? = nil
    ) {
        self.registry = registry
        self.manager = manager
        self.config = config
        self.permissionGranted = permissionGranted
        self.displayCount = displayCount
        self.recentErrors = recentErrors
        self.configPath = configPath
    }
}

func describeWidthSpec(_ spec: ColumnWidthSpec) -> String {
    switch spec {
    case .standard: return "0"
    case .proportion(let value): return "\(value)x"
    case .points(let value): return "\(value)"
    }
}

func describeManagedWindow(_ window: ManagedWindow) -> String {
    let frame = window.frame
    let coords = "(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.size.width)),\(Int(frame.size.height)))"
    let reason = window.floatReason.map { " reason=\($0.rawValue)" } ?? ""
    let minimized = window.isMinimized ? " minimized=true" : ""
    return "pid=\(window.pid) app=\(window.application) title=\(window.title.isEmpty ? "<unknown>" : window.title) frame=\(coords) mode=\(window.mode.rawValue)\(reason)\(minimized)"
}

/// Apply one command to the session, returning human-readable output.
/// Pure Core: no I/O except `reload` re-reading the config file.
@discardableResult
public func dispatch(_ command: CLICommand, session: inout CommandSession) -> String {
    switch command {
    case .help:
        return cliUsage()
    case .reload:
        let (config, messages) = loadGioConfig()
        session.config = config
        if messages.isEmpty {
            return "config reloaded (defaults)"
        }
        return (["config reloaded with messages:"] + messages).joined(separator: "\n")
    case .restart:
        return "restart requires the running Gio session (daemon)"
    case .listWindows:
        let windows = session.registry.managedWindows()
        if windows.isEmpty {
            return "windows=0"
        }
        return (["windows=\(windows.count)"] + windows.map(describeManagedWindow)).joined(separator: "\n")
    case .listWorkspaces:
        var lines = ["workspaces current=\(session.manager.current)"]
        let summaries = session.manager.stackSummaries()
        for summary in summaries {
            if summaries.count > 1 {
                lines.append("display=\(summary.display.rawValue)\(summary.isFocused ? " focused" : "")")
            }
            for entry in summary.workspaces {
                let mark = entry.isActive && summary.isFocused ? "*" : (entry.isActive ? "+" : " ")
                lines.append("\(mark)\(entry.index) columns=\(entry.columns) windows=\(entry.windows)")
            }
        }
        return lines.joined(separator: "\n")
    case .focus(let direction):
        let before = session.manager.currentWorkspace()
        let after = moveFocus(in: before, direction: direction)
        guard after != before else {
            return "focus unchanged (no target)"
        }
        session.manager.update(after)
        let focused = after.focusedWindow.map { "\($0.pid):\($0.elementID)" } ?? "none"
        return "focused column=\(after.focusedColumn) window=\(focused)"
    case .move(let direction):
        let before = session.manager.currentWorkspace()
        // Same mapping as the hotkeys: left/right move the column (FI-06).
        let after = direction == .left || direction == .right
            ? moveColumn(in: before, direction: direction)
            : moveWindow(in: before, direction: direction)
        guard after != before else {
            return "move unchanged (no target)"
        }
        session.manager.update(after)
        return "moved column=\(after.focusedColumn)"
    case .workspace(let number):
        guard WorkspaceManager.range.contains(number), session.manager.switchTo(number) else {
            return "invalid workspace (1...9)"
        }
        return number == session.manager.current
            ? "switched to workspace \(session.manager.current)"
            : "switched to workspace \(session.manager.current) (\(number) is beyond the stack)"
    case .layoutInfo:
        let workspace = session.manager.currentWorkspace()
        var lines = [
            "columns=\(workspace.columns.count) viewportOffset=\(workspace.viewportOffset) focusedColumn=\(workspace.focusedColumn)",
        ]
        for (index, column) in workspace.columns.enumerated() {
            lines.append("column\(index) windows=\(column.windows.count) width=\(describeWidthSpec(column.widthSpec))")
        }
        return lines.joined(separator: "\n")
    case .status:
        return queryStatus(session: session)
    case .logs(let level):
        let lines = GioLog.readFile(minLevel: level ?? .trace)
        if lines.isEmpty {
            return "no log yet"
        }
        return lines.joined(separator: "\n")
    case .setup:
        return runSetup(session: &session)
    case .update:
        return runUpdate()
    case .doctor:
        return runDoctor(session: &session)
    case .uninstall:
        return runUninstall()
    }
}
