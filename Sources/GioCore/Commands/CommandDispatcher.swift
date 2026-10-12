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
    /// NW-02: every assignment re-applies the named workspaces (a no-op
    /// when they did not change).
    public var config: GioConfig {
        didSet {
            // DW-03: layout defaults first, so new named workspaces start with them.
            manager.applyLayoutDefaults(config.layoutDefaults)
            manager.applyNamedWorkspaces(config.workspaces)
        }
    }
    public var permissionGranted: Bool?
    public var displayCount: Int?
    public var recentErrors: [String]
    public var configPath: String?
    /// MM-06: every display's full frame, for `gio move left/right` with
    /// `move-crosses-monitor-at-edge` (the live host fills it before each
    /// IPC command; empty means unknown, so the edge stops the column).
    public var displayFrames: [DisplayID: CGRect] = [:]
    /// DW-02: every display's usable frame, for `gio focus` / `gio move` on
    /// a dwindle workspace (the live host fills it with `displayFrames`;
    /// empty falls back to the full frame, then a 1800x1000 area).
    public var visibleFrames: [DisplayID: CGRect] = [:]

    /// DW-02: the geometry the dwindle verbs measure tiles with: the focused
    /// display's usable frame, the registry's modes (minimized windows have
    /// no tile) and the layout config.
    public var dwindleGeometry: DwindleGeometry {
        let display = manager.focusedDisplay
        var modes: [WindowID: WindowMode] = [:]
        for window in registry.managedWindows() {
            modes[window.id] = window.isMinimized ? .floating : window.mode
        }
        return DwindleGeometry(
            viewport: visibleFrames[display] ?? displayFrames[display] ?? DwindleGeometry.fallback(nil).viewport,
            modes: modes, config: config.makeLayoutConfig()
        )
    }

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
        self.manager.applyLayoutDefaults(config.layoutDefaults)
        self.manager.applyNamedWorkspaces(config.workspaces)
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
                let name = entry.name.map { " name=\($0)" } ?? ""
                let layout = entry.layout == .dwindle ? " layout=dwindle" : ""
                lines.append("\(mark)\(entry.index) columns=\(entry.columns) windows=\(entry.windows)\(layout)\(name)")
            }
        }
        return lines.joined(separator: "\n")
    case .focus(let direction):
        let before = session.manager.currentWorkspace()
        let after = focusNeighbour(in: before, direction: direction, geometry: session.dwindleGeometry)
        guard after != before else {
            return "focus unchanged (no target)"
        }
        session.manager.update(after)
        let focused = after.focusedWindow.map { "\($0.pid):\($0.elementID)" } ?? "none"
        return "focused column=\(after.focusedColumn) window=\(focused)"
    case .move(let direction):
        let before = session.manager.currentWorkspace()
        let geometry = before.layout == .dwindle ? session.dwindleGeometry : nil
        // Same mapping as the hotkeys (NC-14: Alt+Shift+H/J/K/L): the OmniWM
        // window move, across the workspace's edge with the MM-06 toggle.
        // DW-02: in dwindle every direction swaps with the geometric neighbour.
        switch session.manager.moveWindowOrToDisplay(
            direction, frames: session.displayFrames,
            crossesAtEdge: session.config.behavior.moveCrossesMonitorAtEdge, geometry: geometry
        ) {
        case .unchanged:
            return "move unchanged (no target)"
        case .withinWorkspace:
            return "moved column=\(session.manager.currentWorkspace().focusedColumn)"
        case .crossedDisplay:
            let side = switch direction {
            case .left: "on the left"
            case .right: "on the right"
            case .up: "above"
            case .down: "below"
            }
            return "moved window to the display \(side)"
        }
    case .workspace(let number):
        guard WorkspaceManager.range.contains(number), session.manager.switchTo(number) else {
            return "invalid workspace (1...9)"
        }
        return number == session.manager.current
            ? "switched to workspace \(session.manager.current)"
            : "switched to workspace \(session.manager.current) (\(number) is beyond the stack)"
    case .layoutInfo:
        let workspace = session.manager.currentWorkspace()
        if workspace.layout == .dwindle {
            // DW-04: the tree, not columns (each dwindle column is one tile).
            let focused = workspace.focusedWindow.map { "\($0.pid):\($0.elementID)" } ?? "none"
            var lines = [
                "layout=dwindle windows=\(workspace.dwindle.windows.count) focused=\(focused)",
                "tree=\(dwindleTreeSummary(workspace.dwindle))",
            ]
            if let preselection = workspace.dwindle.preselection {
                lines.append("preselection=\(directionName(preselection))")
            }
            if let maximized = workspace.dwindle.maximized {
                lines.append("maximized=\(maximized.pid):\(maximized.elementID)")
            }
            return lines.joined(separator: "\n")
        }
        var lines = [
            "layout=scrolling",
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
    case .update(let install):
        return runUpdate(install: install)
    case .doctor:
        return runDoctor(session: &session)
    case .uninstall:
        return runUninstall()
    case .toggleOverview:
        // The panel is the app's; `IPCRouter` hands the toggle to it.
        return "overview toggled"
    case .moveWindowToDisplay(let number):
        guard let display = session.manager.display(numbered: number) else {
            return "no display \(number)"
        }
        guard session.manager.currentWorkspace().focusedWindow != nil else {
            return "move unchanged (no focused window)"
        }
        guard session.manager.moveWindow(toDisplay: display) else {
            return "move unchanged (already on display \(number))"
        }
        return "moved window to display \(number)"
    case .setLayout(let kind):
        let current = session.manager.currentWorkspace().layout
        let target = kind ?? current.toggled
        guard session.manager.setLayout(target) else {
            return "layout unchanged (workspace \(session.manager.current) is already \(target.rawValue))"
        }
        return "workspace \(session.manager.current) layout=\(target.rawValue)"
    }
}
