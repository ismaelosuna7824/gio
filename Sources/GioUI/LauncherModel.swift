import Foundation
import GioCore

/// Plan §26 launcher model. Entry kinds: installed apps, managed windows
/// (HD-06, focused through the session), Gio commands (executed over IPC —
/// never direct Core access), and `!` shell commands.
/// Matching is a deterministic fuzzy rank; execution lives in the thin
/// AppKit shell (live-only), this file stays pure and tested.
public enum LauncherEntry: Equatable, Sendable {
    case app(name: String, bundleID: String?, path: String)
    /// `id` is the window's `pid:elementID` status text.
    case window(id: String, application: String, windowTitle: String, workspace: Int?)
    case gioCommand(argv: [String], label: String)
    case shellCommand(String)
    /// NW-04: a named workspace of the focused display, by stack index.
    case workspace(index: Int, name: String, icon: String?, color: String?)

    public var title: String {
        switch self {
        case .app(let name, _, _):
            return name
        case .window(_, let application, let windowTitle, _):
            return windowTitle.isEmpty ? application : "\(application) — \(windowTitle)"
        case .gioCommand(_, let label):
            return label
        case .shellCommand(let command):
            return "!\(command)"
        case .workspace(_, let name, _, _):
            return "Go to workspace \(name)"
        }
    }

    /// Stable list identity (titles can repeat across windows).
    public var listID: String {
        switch self {
        case .window(let id, _, _, _):
            return "window:\(id)"
        case .workspace(let index, _, _, _):
            return "workspace:\(index)"
        default:
            return title
        }
    }

    /// Short secondary label telling the kinds apart in the list.
    public var kindLabel: String {
        switch self {
        case .app:
            return "App"
        case .window(_, _, _, let workspace):
            return workspace.map { "Window · workspace \($0)" } ?? "Window"
        case .gioCommand:
            return "Gio command"
        case .shellCommand:
            return "Shell"
        case .workspace:
            return "Workspace"
        }
    }

    /// SF Symbol name, distinct per kind.
    public var symbol: String {
        switch self {
        case .app: return "app"
        case .window: return "macwindow"
        case .gioCommand: return "command"
        case .shellCommand: return "terminal"
        case .workspace(_, _, let icon, _): return icon ?? "square.stack.3d.up.fill"
        }
    }

    /// Named workspaces first on an equal rank (typing a workspace's name
    /// means going there), then windows: an app that is already running is
    /// better reached through its window than launched again.
    fileprivate var kindOrder: Int {
        switch self {
        case .workspace: return 0
        case .window: return 1
        case .app: return 2
        case .gioCommand: return 3
        case .shellCommand: return 4
        }
    }

    /// Nil means no match. A window matches by its app name, or by its title
    /// (one step worse, so a title never outranks a real app-name match), or
    /// by both together ("code main").
    fileprivate func rank(for query: String) -> Int? {
        switch self {
        case .window(_, let application, let windowTitle, _):
            let candidates = [
                rankMatch(query: query, candidate: application),
                rankMatch(query: query, candidate: windowTitle).map { $0 + 1 },
                rankMatch(query: query, candidate: "\(application) \(windowTitle)"),
            ]
            return candidates.compactMap { $0 }.min()
        case .workspace(_, let name, _, _):
            return rankMatch(query: query, candidate: name)
        default:
            return rankMatch(query: query, candidate: title)
        }
    }
}

/// Launcher rows for the session's windows. Minimized windows are left out
/// (nothing to focus); order is by app then title so results are stable.
public func launcherWindowEntries(from facts: [WindowFact]) -> [LauncherEntry] {
    facts.filter { !$0.isMinimized }
        .sorted { ($0.application, $0.title, $0.id) < ($1.application, $1.title, $1.id) }
        .map {
            .window(id: $0.id, application: $0.application, windowTitle: $0.title, workspace: $0.workspace)
        }
}

/// NW-04: launcher rows for the named workspaces of the focused display's
/// stack (dynamic workspaces have no name to type).
public func launcherWorkspaceEntries(from facts: SessionFacts?) -> [LauncherEntry] {
    guard let facts else {
        return []
    }
    return focusedStack(facts).compactMap { entry in
        entry.name.map { .workspace(index: entry.index, name: $0, icon: entry.icon, color: entry.color) }
    }
}

/// The IPC verb an entry runs through the session, if any: Gio commands
/// as typed, a workspace as `workspace N` (the keyboard action path, so it
/// carries the focus intent).
public func launcherIPCArguments(_ entry: LauncherEntry) -> [String]? {
    switch entry {
    case .gioCommand(let argv, _): return argv
    case .workspace(let index, _, _, _): return ["workspace", "\(index)"]
    case .app, .window, .shellCommand: return nil
    }
}

/// Rank a query against a candidate name (both lowered by caller contract —
/// this function lowercases defensively). Nil means no match. Lower wins:
/// prefix (0), substring (1), ordered subsequence (2).
public func rankMatch(query: String, candidate: String) -> Int? {
    let query = query.lowercased()
    let candidate = candidate.lowercased()
    guard !query.isEmpty, !candidate.isEmpty else {
        return nil
    }
    if candidate.hasPrefix(query) {
        return 0
    }
    if candidate.contains(query) {
        return 1
    }
    var cursor = candidate.startIndex
    for char in query {
        guard let found = candidate[cursor...].firstIndex(of: char) else {
            return nil
        }
        cursor = candidate.index(after: found)
    }
    return 2
}

/// Rank apps and windows together: best match first, then windows before
/// apps, then by title (and id) so the order never depends on input order.
public func searchLauncherEntries(_ query: String, in apps: [LauncherEntry]) -> [LauncherEntry] {
    apps.compactMap { entry in
        entry.rank(for: query).map { ($0, entry) }
    }
    .sorted { lhs, rhs in
        if lhs.0 != rhs.0 {
            return lhs.0 < rhs.0
        }
        if lhs.1.kindOrder != rhs.1.kindOrder {
            return lhs.1.kindOrder < rhs.1.kindOrder
        }
        return (lhs.1.title, lhs.1.listID) < (rhs.1.title, rhs.1.listID)
    }
    .map(\.1)
}

public enum LauncherRoute: Equatable, Sendable {
    case empty
    case runEntry(LauncherEntry)
    case noMatch
    case invalid(String)
}

/// Route raw input: `> …` forces a Gio command, `! …` a shell command,
/// anything else fuzzy-searches apps and windows (`apps` holds both). Unknown Gio verbs become `.invalid`
/// with the parser's reason instead of failing silently.
public func routeLauncherInput(_ text: String, apps: [LauncherEntry]) -> LauncherRoute {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
        return .empty
    }
    if trimmed.hasPrefix(">") {
        let command = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        let argv = command.split(separator: " ").map(String.init)
        switch parseCLICommand(argv) {
        case .success(let parsed):
            return .runEntry(.gioCommand(argv: argv, label: describeAction(parsed)))
        case .failure:
            return .invalid("unknown Gio command: \(command)")
        }
    }
    if trimmed.hasPrefix("!") {
        let command = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else {
            return .invalid("empty shell command")
        }
        return .runEntry(.shellCommand(command))
    }
    let matches = searchLauncherEntries(trimmed, in: apps)
    guard let first = matches.first else {
        return .noMatch
    }
    return .runEntry(first)
}

func describeAction(_ command: CLICommand) -> String {
    switch command {
    case .reload: return "reload"
    case .restart: return "restart"
    case .listWindows: return "list-windows"
    case .listWorkspaces: return "list-workspaces"
    case .focus(let direction): return "focus \(direction)"
    case .move(let direction): return "move \(direction)"
    case .workspace(let number): return "workspace \(number)"
    case .layoutInfo: return "layout info"
    case .status: return "status"
    case .setup: return "setup"
    case .update(let install): return install ? "update --install" : "update"
    case .doctor: return "doctor"
    case .uninstall: return "uninstall"
    case .logs(let level): return level.map { "logs --level \($0.name)" } ?? "logs"
    case .help: return "help"
    case .toggleOverview: return "overview"
    case .moveWindowToDisplay(let number): return "move-window-to-display \(number)"
    case .setLayout(let kind): return "layout \(kind?.rawValue ?? "toggle")"
    case .action(let action): return "action \(action)"
    }
}

/// Scan directories for `.app` bundles (top level only). Name comes from
/// the bundle filename (deterministic, unlocalized); the bundle ID is read
/// when its Info.plist parses, else nil. Sorted by name.
public func scanApplications(directories: [String]) -> [LauncherEntry] {
    var found: [LauncherEntry] = []
    for directory in directories {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            continue
        }
        for item in items where item.hasSuffix(".app") {
            let path = (directory as NSString).appendingPathComponent(item)
            let name = String(item.dropLast(".app".count))
            let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
            var bundleID: String?
            if let data = FileManager.default.contents(atPath: plist),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
            {
                bundleID = info["CFBundleIdentifier"] as? String
            }
            found.append(.app(name: name, bundleID: bundleID, path: path))
        }
    }
    return found.sorted { $0.title < $1.title }
}

public func defaultApplicationDirectories() -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["/Applications", home + "/Applications", "/System/Applications"]
}
