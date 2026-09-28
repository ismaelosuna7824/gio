import Foundation
import GioCore

/// Plan §26 launcher model. Three entry kinds: installed apps, Gio commands
/// (executed over IPC — never direct Core access), and `!` shell commands.
/// Matching is a deterministic fuzzy rank; execution lives in the thin
/// AppKit shell (live-only), this file stays pure and tested.
public enum LauncherEntry: Equatable, Sendable {
    case app(name: String, bundleID: String?, path: String)
    case gioCommand(argv: [String], label: String)
    case shellCommand(String)

    public var title: String {
        switch self {
        case .app(let name, _, _):
            return name
        case .gioCommand(_, let label):
            return label
        case .shellCommand(let command):
            return "!\(command)"
        }
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

public func searchLauncherEntries(_ query: String, in apps: [LauncherEntry]) -> [LauncherEntry] {
    apps.compactMap { entry in
        rankMatch(query: query, candidate: entry.title).map { ($0, entry) }
    }
    .sorted { lhs, rhs in
        lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1.title < rhs.1.title
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
/// anything else fuzzy-searches apps. Unknown Gio verbs become `.invalid`
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
    case .update: return "update"
    case .doctor: return "doctor"
    case .uninstall: return "uninstall"
    case .logs(let level): return level.map { "logs --level \($0.name)" } ?? "logs"
    case .help: return "help"
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
