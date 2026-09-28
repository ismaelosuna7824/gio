import CoreGraphics
import Foundation

/// CLI verbs for `gio-poc`. Window indices are positional within one fresh
/// enumeration per invocation. Pure parsing, no macOS calls — unit tested.
public enum CLICommand: Equatable, Sendable {
    case listWindows
    case focus(index: Int)
    case move(index: Int, x: CGFloat, y: CGFloat)
    case resize(index: Int, width: CGFloat, height: CGFloat)
    case tile
    case events
    case help
}

public enum CLICommandError: Error, Equatable, Sendable {
    case noArguments
    case unknownCommand(String)
    case missingArgument(name: String, command: String)
    case invalidNumber(String)
    case nonPositiveSize
}

public func parseCLICommand(_ args: [String]) -> Result<CLICommand, CLICommandError> {
    guard let verb = args.first else {
        return .failure(.noArguments)
    }
    switch verb {
    case "list-windows":
        return .success(.listWindows)
    case "focus":
        guard args.count > 1 else {
            return .failure(.missingArgument(name: "index", command: "focus"))
        }
        guard let index = Int(args[1]) else {
            return .failure(.invalidNumber(args[1]))
        }
        return .success(.focus(index: index))
    case "move":
        guard args.count > 3 else {
            return .failure(.missingArgument(name: "index x y", command: "move"))
        }
        guard let index = Int(args[1]) else {
            return .failure(.invalidNumber(args[1]))
        }
        guard let x = Double(args[2]) else {
            return .failure(.invalidNumber(args[2]))
        }
        guard let y = Double(args[3]) else {
            return .failure(.invalidNumber(args[3]))
        }
        return .success(.move(index: index, x: CGFloat(x), y: CGFloat(y)))
    case "resize":
        guard args.count > 3 else {
            return .failure(.missingArgument(name: "index width height", command: "resize"))
        }
        guard let index = Int(args[1]) else {
            return .failure(.invalidNumber(args[1]))
        }
        guard let width = Double(args[2]) else {
            return .failure(.invalidNumber(args[2]))
        }
        guard let height = Double(args[3]) else {
            return .failure(.invalidNumber(args[3]))
        }
        guard width > 0, height > 0 else {
            return .failure(.nonPositiveSize)
        }
        return .success(.resize(index: index, width: CGFloat(width), height: CGFloat(height)))
    case "events":
        return .success(.events)
    case "tile":
        return .success(.tile)
    case "help", "--help", "-h":
        return .success(.help)
    default:
        return .failure(.unknownCommand(verb))
    }
}

public func cliUsage() -> String {
    """
    gio-poc — Gio Phase 0 Accessibility POC

    Usage:
      gio-poc list-windows
      gio-poc focus <index>
      gio-poc move <index> <x> <y>
      gio-poc resize <index> <width> <height>
      gio-poc tile
      gio-poc events
      gio-poc help

    Indices come from a fresh `list-windows` enumeration per invocation.
    Requires Accessibility permission: System Settings → Privacy & Security →
    Accessibility, then retry.
    """
}
