import GioCore

/// DD-02: pure labels for the Overview dashboard and the sidebar header.

public struct StateBadge: Equatable, Sendable {
    public let kind: StatusKind
    public let label: String
    public let symbol: String
}

/// Compact badge for a window's state in the Overview list.
public func windowStateBadge(_ state: WindowState) -> StateBadge {
    switch state {
    case .tiled:
        return StateBadge(kind: .neutral, label: "Tiled", symbol: "rectangle.split.3x1")
    case .fullscreen:
        return StateBadge(kind: .info, label: "Fullscreen", symbol: "arrow.up.left.and.arrow.down.right")
    case .minimized:
        return StateBadge(kind: .neutral, label: "Minimized", symbol: "minus.rectangle")
    case .hidden:
        return StateBadge(kind: .neutral, label: "Hidden", symbol: "eye.slash")
    case .floating(let reason):
        let detail: String?
        switch reason {
        case .dialog: detail = "Dialog"
        case .floatingSubrole: detail = "Panel"
        case .notResizable: detail = "Fixed size"
        case .rule: detail = "Rule"
        case .manual: detail = "Toggled"
        case nil: detail = nil
        }
        return StateBadge(
            kind: .info, label: detail.map { "Floating · \($0)" } ?? "Floating", symbol: "macwindow.on.rectangle"
        )
    }
}

public struct MotionOverview: Equatable, Sendable {
    public let value: String
    public let detail: String
}

/// How windows move right now: the effective renderer and the curve.
public func motionSummary(_ config: AnimationsSectionConfig, screenRecording: Bool, windowServer: Bool) -> MotionOverview {
    guard config.enabled else {
        return MotionOverview(value: "Off", detail: "Windows move instantly")
    }
    let value = switch effectiveRenderer(config: config, permission: screenRecording, windowServer: windowServer) {
    case .live: "Live"
    case .snapshot: "Snapshot"
    case .ax: "Accessibility"
    }
    if config.renderer == .live, !windowServer {
        return MotionOverview(value: value, detail: "Live needs SkyLight")
    }
    if config.renderer == .snapshot, !screenRecording {
        return MotionOverview(value: value, detail: "Snapshot needs Screen Recording")
    }
    switch config.curve {
    case .spring: return MotionOverview(value: value, detail: "Spring motion")
    case .easeOut: return MotionOverview(value: value, detail: "Ease-out · \(config.durationMilliseconds) ms")
    }
}

public struct SessionStatus: Equatable, Sendable {
    public let kind: StatusKind
    public let label: String
}

/// The sidebar header's status dot.
public func sessionStatus(_ facts: SessionFacts?) -> SessionStatus {
    guard let facts else {
        return SessionStatus(kind: .neutral, label: "Starting")
    }
    return facts.accessibilityGranted
        ? SessionStatus(kind: .ok, label: "Running")
        : SessionStatus(kind: .warning, label: "Needs access")
}

/// `current / total` on the focused display's stack; just the current
/// index when the stack is unknown.
public func workspaceTotals(_ facts: SessionFacts) -> String {
    let display = facts.displays.first { $0.id == facts.strip?.displayID }
        ?? (facts.displays.count == 1 ? facts.displays.first : nil)
    guard let stack = display?.stack, !stack.isEmpty else {
        return "\(facts.currentWorkspace)"
    }
    return "\(facts.currentWorkspace) / \(stack.count)"
}

// MARK: - NW-04 workspace names

/// "1 · Code" for a named workspace, "Workspace 3" for a dynamic one.
public func workspaceTitle(_ entry: WorkspaceEntry) -> String {
    entry.name.map { "\(entry.index) · \($0)" } ?? "Workspace \(entry.index)"
}

/// "Code", or "Workspace 3" without a name.
public func workspaceShortName(_ entry: WorkspaceEntry) -> String {
    entry.name ?? "Workspace \(entry.index)"
}

/// The focused display's stack: the strip's display, else the only one.
func focusedStack(_ facts: SessionFacts) -> [WorkspaceEntry] {
    let display = facts.displays.first { $0.id == facts.strip?.displayID }
        ?? (facts.displays.count == 1 ? facts.displays.first : nil)
    return display?.stack ?? []
}

/// Header of the Overview's live strip: the shown workspace's title.
public func stripTitle(_ facts: SessionFacts) -> String {
    let index = facts.strip?.workspace ?? facts.currentWorkspace
    let entry = focusedStack(facts).first { $0.index == index }
        ?? WorkspaceEntry(index: index, windows: 0, columns: 0, isActive: true)
    return workspaceTitle(entry)
}

/// Overview window-list header: "1 · Code" when the single display's stack
/// names that index. Window indices are per display, so with several
/// displays the plain "Workspace N" stays.
public func windowGroupTitle(workspace: Int?, facts: SessionFacts) -> String {
    guard let workspace else {
        return "Other windows"
    }
    guard facts.displays.count == 1,
          let entry = facts.displays[0].stack.first(where: { $0.index == workspace })
    else {
        return "Workspace \(workspace)"
    }
    return workspaceTitle(entry)
}

/// A named pill's trailing count: "Empty", or just the number.
public func compactWindowCount(_ count: Int) -> String {
    count == 0 ? "Empty" : "\(count)"
}
