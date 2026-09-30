import Foundation

/// NW-01: whether arriving at an `open-on-workspace` destination also
/// takes the user there.
public enum WorkspaceFollowPolicy: String, Equatable, Sendable, CaseIterable {
    /// Follow only when the window's app is frontmost as the window appears
    /// (the user just launched or used it); otherwise the window goes there
    /// silently.
    case whenActive = "when-active"
    case always
    case never
}

/// Plan §18 rule: opinions about newly created windows, matched by app.
/// Matching is exact: no globs, no prefixes, no surprises. NW-01: a rule
/// with `bundleID` matches by bundle identifier when the window's is known
/// (preferred), else by `app` name; an empty `app` never matches a name.
public struct WindowRule: Equatable, Sendable {
    public var app: String
    public var bundleID: String?
    public var mode: WindowMode?
    /// Index semantics (`workspace = N`): the focused display's stack.
    public var workspace: Int?
    /// NW-01: a `[[workspace]]` name; wins over `workspace` when both parse.
    public var openOnWorkspace: String?
    public var follow: WorkspaceFollowPolicy

    public init(
        app: String,
        bundleID: String? = nil,
        mode: WindowMode? = nil,
        workspace: Int? = nil,
        openOnWorkspace: String? = nil,
        follow: WorkspaceFollowPolicy = .whenActive
    ) {
        self.app = app
        self.bundleID = bundleID
        self.mode = mode
        self.workspace = workspace
        self.openOnWorkspace = openOnWorkspace
        self.follow = follow
    }

    public func matches(app name: String, bundleID windowBundle: String?) -> Bool {
        if let bundleID, let windowBundle {
            return bundleID == windowBundle
        }
        return !app.isEmpty && app == name
    }
}

/// What the rules decided for one window. Nil fields mean "no opinion".
public struct RuleOutcome: Equatable, Sendable {
    public var mode: WindowMode?
    public var workspace: Int?
    public var openOnWorkspace: String?
    public var follow: WorkspaceFollowPolicy

    public init(
        mode: WindowMode? = nil,
        workspace: Int? = nil,
        openOnWorkspace: String? = nil,
        follow: WorkspaceFollowPolicy = .whenActive
    ) {
        self.mode = mode
        self.workspace = workspace
        self.openOnWorkspace = openOnWorkspace
        self.follow = follow
    }

    public static let none = RuleOutcome()
}

/// First matching rule wins, entirely. Later rules never merge: one app,
/// one verdict, predictable from reading the file top to bottom.
public func evaluateRules(_ rules: [WindowRule], app: String, bundleID: String? = nil) -> RuleOutcome {
    for rule in rules where rule.matches(app: app, bundleID: bundleID) {
        return RuleOutcome(
            mode: rule.mode, workspace: rule.workspace,
            openOnWorkspace: rule.openOnWorkspace, follow: rule.follow
        )
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
