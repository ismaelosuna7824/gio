import Foundation

/// Plan §22 machine query: the session snapshot scripts, the launcher and
/// the bar consume. Keys mirror the plan sketch; `focusedWindow` is
/// `pid:elementID` (stable and parseable — the sketch's name is illustrative).
public func queryStatus(session: CommandSession) -> String {
    let workspace = session.manager.currentWorkspace()
    let focused: Any = workspace.focusedWindow.map { "\($0.pid):\($0.elementID)" }
        ?? NSNull()
    let windows = workspace.columns.map(\.windows.count).reduce(0, +)
    let managed = session.registry.managedWindows()
    var modes: [String: Int] = ["tiled": 0, "floating": 0, "fullscreen": 0]
    for window in managed {
        modes[window.mode.rawValue, default: 0] += 1
    }
    let floating: [[String: String]] = managed.filter { $0.mode == .floating }.map { window in
        var entry = [
            "id": "\(window.id.pid):\(window.id.elementID)",
            "app": window.application,
            "title": window.title,
        ]
        if let reason = window.floatReason {
            entry["reason"] = reason.rawValue
        }
        return entry
    }
    let minimized: [[String: String]] = managed.filter(\.isMinimized).map { window in
        [
            "id": "\(window.id.pid):\(window.id.elementID)",
            "app": window.application,
            "title": window.title,
        ]
    }
    let dict: [String: Any] = [
        "workspace": session.manager.current,
        "focusedWindow": focused,
        "columns": workspace.columns.count,
        "windows": windows,
        "modes": modes,
        "floatingWindows": floating,
        "minimizedWindows": minimized,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }
    return text
}

/// Server-side argv handling shared by every transport: parse once, dispatch,
/// wrap. Unknown verbs become failed responses, never crashes.
///
/// `restartAvailable` is true only in a host that can really restart itself
/// (HD-05): it acknowledges `restart` and performs the relaunch after replying.
public func dispatchIPC(
    _ argv: [String], session: inout CommandSession, restartAvailable: Bool = false
) -> IPCResponse {
    switch parseCLICommand(argv) {
    case .success(let command):
        if restartAvailable, command.requestsSessionRestart {
            return IPCResponse(ok: true, output: restartAcknowledgement)
        }
        return IPCResponse(ok: true, output: dispatch(command, session: &session))
    case .failure(let error):
        return IPCResponse(ok: false, error: String(describing: error))
    }
}

public let restartAcknowledgement = "restarting Gio session"

extension CLICommand {
    /// Commands the hosting session must act on after replying.
    public var requestsSessionRestart: Bool {
        self == .restart
    }
}
