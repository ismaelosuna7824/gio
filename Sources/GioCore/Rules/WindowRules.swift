import CoreGraphics
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

/// WR-01: a rule's `title` matcher, a regular expression searched in the
/// window title (case-insensitive unless the pattern opts out with an
/// inline flag such as `(?-i)`). Titles are compared in memory only and
/// never logged; equality is the pattern text.
public struct TitlePattern: Equatable, @unchecked Sendable {
    public let pattern: String
    // Immutable after init; NSRegularExpression is safe to share.
    private let regex: NSRegularExpression

    /// Nil for an empty or invalid pattern.
    public init?(_ pattern: String) {
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else {
            return nil
        }
        self.pattern = pattern
        self.regex = regex
    }

    public func matches(_ title: String) -> Bool {
        regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    public static func == (lhs: TitlePattern, rhs: TitlePattern) -> Bool {
        lhs.pattern == rhs.pattern
    }
}

/// WR-03: a rule's `default-column-width`, with the `[layout]` key's
/// semantics: a fraction of the strip when ≤ 1, points above. Nil unless
/// positive and finite. The parser and the Rules form share it.
public func ruleColumnWidth(_ value: Double) -> ColumnWidthSpec? {
    guard value.isFinite, value > 0 else {
        return nil
    }
    return value <= 1 ? .proportion(CGFloat(value)) : .points(CGFloat(value))
}

/// WR-05: `min-width` / `max-width` are points above 1 (a value ≤ 1 would
/// read like a fraction, which these keys do not take).
public func isValidRuleWidthLimit(_ value: Double) -> Bool {
    value.isFinite && value > 1
}

/// Plan §18 rule: opinions about newly created windows, matched by app.
/// App matching is exact: no globs, no prefixes, no surprises. NW-01: a rule
/// with `bundleID` matches by bundle identifier when the window's is known
/// (preferred), else by `app` name; an empty `app` never matches a name.
/// WR-01: `title` narrows the app match (AND) or, alone, matches any app; a
/// window without a title never matches a title rule.
public struct WindowRule: Equatable, Sendable {
    public var app: String
    public var bundleID: String?
    public var title: TitlePattern?
    public var mode: WindowMode?
    /// Index semantics (`workspace = N`): the focused display's stack (the
    /// rule display's stack with `openOnDisplay`).
    public var workspace: Int?
    /// NW-01: a `[[workspace]]` name; wins over `workspace` when both parse.
    public var openOnWorkspace: String?
    public var follow: WorkspaceFollowPolicy
    /// WR-03: the new window's column width (`.proportion` or `.points`).
    public var columnWidth: ColumnWidthSpec?
    /// WR-03: the new window's column opens maximized (the Alt+F state).
    public var openMaximized: Bool
    /// WR-04: display number as `[[workspace]] display` counts them.
    public var openOnDisplay: Int?
    /// WR-04: false keeps the strip's focus where it is (no follow either).
    public var openFocused: Bool
    /// WR-05: points, clamping the width of the window's column.
    public var minWidth: CGFloat?
    public var maxWidth: CGFloat?

    public init(
        app: String,
        bundleID: String? = nil,
        title: TitlePattern? = nil,
        mode: WindowMode? = nil,
        workspace: Int? = nil,
        openOnWorkspace: String? = nil,
        follow: WorkspaceFollowPolicy = .whenActive,
        columnWidth: ColumnWidthSpec? = nil,
        openMaximized: Bool = false,
        openOnDisplay: Int? = nil,
        openFocused: Bool = true,
        minWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil
    ) {
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.mode = mode
        self.workspace = workspace
        self.openOnWorkspace = openOnWorkspace
        self.follow = follow
        self.columnWidth = columnWidth
        self.openMaximized = openMaximized
        self.openOnDisplay = openOnDisplay
        self.openFocused = openFocused
        self.minWidth = minWidth
        self.maxWidth = maxWidth
    }

    public func matches(app name: String, bundleID windowBundle: String?, title windowTitle: String? = nil) -> Bool {
        if !app.isEmpty || bundleID != nil {
            if let bundleID, let windowBundle {
                guard bundleID == windowBundle else {
                    return false
                }
            } else if app.isEmpty || app != name {
                return false
            }
        } else if title == nil {
            return false
        }
        guard let title else {
            return true
        }
        guard let windowTitle, !windowTitle.isEmpty else {
            return false
        }
        return title.matches(windowTitle)
    }
}

/// What the rules decided for one window. Nil fields mean "no opinion".
public struct RuleOutcome: Equatable, Sendable {
    public var mode: WindowMode?
    public var workspace: Int?
    public var openOnWorkspace: String?
    public var follow: WorkspaceFollowPolicy
    public var columnWidth: ColumnWidthSpec?
    public var openMaximized: Bool
    /// The rule's display number (`open-on-display`), resolved at placement.
    public var display: Int?
    public var openFocused: Bool
    public var widthLimits: ColumnWidthLimits?
    /// The winning rule has a `title` matcher (WR-01 re-check).
    public var matchedByTitle: Bool

    public init(
        mode: WindowMode? = nil,
        workspace: Int? = nil,
        openOnWorkspace: String? = nil,
        follow: WorkspaceFollowPolicy = .whenActive,
        columnWidth: ColumnWidthSpec? = nil,
        openMaximized: Bool = false,
        display: Int? = nil,
        openFocused: Bool = true,
        widthLimits: ColumnWidthLimits? = nil,
        matchedByTitle: Bool = false
    ) {
        self.mode = mode
        self.workspace = workspace
        self.openOnWorkspace = openOnWorkspace
        self.follow = follow
        self.columnWidth = columnWidth
        self.openMaximized = openMaximized
        self.display = display
        self.openFocused = openFocused
        self.widthLimits = widthLimits
        self.matchedByTitle = matchedByTitle
    }

    public static let none = RuleOutcome()
}

/// First matching rule wins, entirely. Later rules never merge: one app,
/// one verdict, predictable from reading the file top to bottom.
public func evaluateRules(
    _ rules: [WindowRule], app: String, bundleID: String? = nil, title: String? = nil
) -> RuleOutcome {
    for rule in rules where rule.matches(app: app, bundleID: bundleID, title: title) {
        return RuleOutcome(
            mode: rule.mode, workspace: rule.workspace,
            openOnWorkspace: rule.openOnWorkspace, follow: rule.follow,
            columnWidth: rule.columnWidth, openMaximized: rule.openMaximized,
            display: rule.openOnDisplay, openFocused: rule.openFocused,
            widthLimits: ColumnWidthLimits.from(min: rule.minWidth, max: rule.maxWidth),
            matchedByTitle: rule.title != nil
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
/// current otherwise) shaped by the rule (width, maximized), and focuses it
/// there unless the rule says `open-focused = false`. Invalid rule
/// workspaces fall back to current — never to nowhere. Duplicate IDs throw
/// from the registry; re-registration is the caller's update path.
@discardableResult
public func placeWindow(
    _ window: ManagedWindow,
    rules: [WindowRule],
    appKey: String,
    registry: WindowRegistry,
    manager: inout WorkspaceManager
) throws -> WindowPlacement {
    let outcome = evaluateRules(rules, app: appKey, title: window.title)
    var placed = window
    placed.mode = outcome.mode ?? .tiled
    placed.widthLimits = outcome.widthLimits
    try registry.register(placed)
    let destID = placeArrival(placed.id, outcome: outcome, takesFocus: outcome.openFocused, manager: &manager)
    return WindowPlacement(
        workspace: manager.location(of: destID)?.index ?? manager.current,
        column: (manager.workspace(id: destID)?.columns.count ?? 1) - 1
    )
}
