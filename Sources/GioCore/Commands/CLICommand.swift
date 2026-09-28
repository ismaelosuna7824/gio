import Foundation

/// Plan §21 command language. Parsing is total and UI-free; the `gio`
/// executable arrives with IPC (RW-17), when commands can reach a live
/// session. Until then this model plus the dispatcher are exercised
/// in-process (and by the IPC server later).
public enum CLICommand: Equatable, Sendable {
    case reload
    case restart
    case listWindows
    case listWorkspaces
    case focus(FocusDirection)
    case move(FocusDirection)
    case workspace(Int)
    case layoutInfo
    case status
    case setup
    case update
    case doctor
    case uninstall
    case logs(LogLevel?)
    case help
}

public enum CLICommandError: Error, Equatable, Sendable {
    case noArguments
    case unknownCommand(String)
    case missingArgument(name: String, command: String)
    case invalidWorkspace(String)
    case invalidLevel(String)
}

public func parseCLICommand(_ args: [String]) -> Result<CLICommand, CLICommandError> {
    guard let verb = args.first else {
        return .failure(.noArguments)
    }
    switch verb {
    case "reload": return .success(.reload)
    case "restart": return .success(.restart)
    case "list-windows": return .success(.listWindows)
    case "list-workspaces": return .success(.listWorkspaces)
    case "focus", "move":
        guard args.count > 1 else {
            return .failure(.missingArgument(name: "left|right|up|down", command: verb))
        }
        let direction: FocusDirection?
        switch args[1] {
        case "left": direction = .left
        case "right": direction = .right
        case "up": direction = .up
        case "down": direction = .down
        default: direction = nil
        }
        guard let direction else {
            return .failure(.missingArgument(name: "left|right|up|down", command: verb))
        }
        return verb == "focus" ? .success(.focus(direction)) : .success(.move(direction))
    case "workspace":
        guard args.count > 1, let number = Int(args[1]) else {
            return .failure(.missingArgument(name: "1...9", command: "workspace"))
        }
        guard WorkspaceManager.range.contains(number) else {
            return .failure(.invalidWorkspace(args[1]))
        }
        return .success(.workspace(number))
    case "layout":
        guard args.count > 1, args[1] == "info" else {
            return .failure(.missingArgument(name: "info", command: "layout"))
        }
        return .success(.layoutInfo)
    case "status":
        return .success(.status)
    case "setup":
        return .success(.setup)
    case "update":
        return .success(.update)
    case "doctor":
        return .success(.doctor)
    case "uninstall":
        return .success(.uninstall)
    case "logs":
        guard args.count > 1 else {
            return .success(.logs(nil))
        }
        guard args.count == 3, args[1] == "--level" else {
            return .failure(.invalidLevel(args.dropFirst().joined(separator: " ")))
        }
        guard let level = LogLevel(name: args[2]) else {
            return .failure(.invalidLevel(args[2]))
        }
        return .success(.logs(level))
    case "help", "--help", "-h":
        return .success(.help)
    default:
        return .failure(.unknownCommand(verb))
    }
}

public func cliUsage() -> String {
    """
    gio — Gio window manager CLI

    Usage:
      gio reload
      gio restart
      gio list-windows
      gio list-workspaces
      gio focus left|right|up|down
      gio move left|right|up/down
      gio workspace 1...9
      gio layout info
      gio status
      gio setup
      gio update
      gio doctor
      gio uninstall
      gio logs [--level trace|debug|info|warn|error]
      gio help

    Stateful verbs act on the running session via IPC (RW-17).
    """
}
