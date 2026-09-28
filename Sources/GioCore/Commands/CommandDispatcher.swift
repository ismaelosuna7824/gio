import CoreGraphics
import Foundation

/// The live state commands act on. Owned by the session host (one-shot
/// callers, the IPC server in RW-17, the daemon later) — the dispatcher
/// never stores it.
public struct CommandSession {
    public var registry: WindowRegistry
    public var manager: WorkspaceManager
    public var config: GioConfig

    public init(
        registry: WindowRegistry = WindowRegistry(),
        manager: WorkspaceManager = WorkspaceManager(),
        config: GioConfig = defaultGioConfig()
    ) {
        self.registry = registry
        self.manager = manager
        self.config = config
    }
}

func describeManagedWindow(_ window: ManagedWindow) -> String {
    let frame = window.frame
    let coords = "(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.size.width)),\(Int(frame.size.height)))"
    return "pid=\(window.pid) app=\(window.application) title=\(window.title.isEmpty ? "<unknown>" : window.title) frame=\(coords) mode=\(window.mode.rawValue)"
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
        for index in WorkspaceManager.range {
            let workspace = session.manager.workspace(index)!
            let mark = index == session.manager.current ? "*" : " "
            lines.append(
                "\(mark)\(index) columns=\(workspace.columns.count) windows=\(workspace.columns.map(\.windows.count).reduce(0, +))"
            )
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
        let after = moveWindow(in: before, direction: direction)
        guard after != before else {
            return "move unchanged (no target)"
        }
        session.manager.update(after)
        return "moved column=\(after.focusedColumn)"
    case .workspace(let number):
        guard session.manager.switchTo(number) else {
            return "invalid workspace (1...9)"
        }
        return "switched to workspace \(number)"
    case .layoutInfo:
        let workspace = session.manager.currentWorkspace()
        var lines = [
            "columns=\(workspace.columns.count) viewportOffset=\(workspace.viewportOffset) focusedColumn=\(workspace.focusedColumn)",
        ]
        for (index, column) in workspace.columns.enumerated() {
            lines.append("column\(index) windows=\(column.windows.count) width=\(column.width)")
        }
        return lines.joined(separator: "\n")
    }
}
