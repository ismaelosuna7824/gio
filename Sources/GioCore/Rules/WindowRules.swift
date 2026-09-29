import Foundation

/// Plan §18 rule: opinions about newly created windows, matched by app key.
/// The key is whatever the caller supplies — app name today (what discovery
/// provides), bundle ID when config lands (Phase 14). Matching is exact:
/// no globs, no prefixes, no surprises.
public struct WindowRule: Equatable, Sendable {
    public var app: String
    public var mode: WindowMode?
    public var workspace: Int?

    public init(app: String, mode: WindowMode? = nil, workspace: Int? = nil) {
        self.app = app
        self.mode = mode
        self.workspace = workspace
    }
}

/// What the rules decided for one window. Nil fields mean "no opinion".
public struct RuleOutcome: Equatable, Sendable {
    public var mode: WindowMode?
    public var workspace: Int?

    public static let none = RuleOutcome(mode: nil, workspace: nil)
}

/// First matching rule wins, entirely. Later rules never merge: one app,
/// one verdict, predictable from reading the file top to bottom.
public func evaluateRules(_ rules: [WindowRule], app: String) -> RuleOutcome {
    for rule in rules where rule.app == app {
        return RuleOutcome(mode: rule.mode, workspace: rule.workspace)
    }
    return .none
}

/// Where a placed window landed.
public struct WindowPlacement: Equatable, Sendable {
    public var workspace: Int
    public var column: Int
}

/// Plan §18 pipeline, pure form: Window Created → Rules → Workspace → Mode.
/// Registers the window (mode from rules, default tiled), appends it as a
/// new last column in the destination workspace (rule workspace when valid,
/// current otherwise), and focuses it there. Invalid rule workspaces fall
/// back to current — never to nowhere. Duplicate IDs throw from the
/// registry; re-registration is the caller's update path.
@discardableResult
public func placeWindow(
    _ window: ManagedWindow,
    rules: [WindowRule],
    appKey: String,
    registry: WindowRegistry,
    manager: inout WorkspaceManager
) throws -> WindowPlacement {
    let outcome = evaluateRules(rules, app: appKey)
    var placed = window
    placed.mode = outcome.mode ?? .tiled
    try registry.register(placed)
    let destID = outcome.workspace.flatMap { manager.ruleTarget($0) } ?? manager.currentID
    var dest = manager.workspace(id: destID)!
    var column = Column(
        id: ColumnID((dest.columns.map(\.id.rawValue).max() ?? 0) + 1),
        width: 0,
        windows: [placed.id]
    )
    column.focusedWindowIndex = 0
    dest.columns.append(column)
    dest.focusedColumn = dest.columns.count - 1
    dest.focusedWindow = placed.id
    manager.update(dest)
    return WindowPlacement(
        workspace: manager.location(of: destID)?.index ?? manager.current,
        column: dest.columns.count - 1
    )
}
