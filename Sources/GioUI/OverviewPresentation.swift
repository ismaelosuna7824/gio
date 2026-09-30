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
public func motionSummary(_ config: AnimationsSectionConfig, screenRecording: Bool) -> MotionOverview {
    guard config.enabled else {
        return MotionOverview(value: "Off", detail: "Windows move instantly")
    }
    let renderer = effectiveRenderer(config: config, permission: screenRecording)
    let value = renderer == .snapshot ? "Snapshot" : "Accessibility"
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
