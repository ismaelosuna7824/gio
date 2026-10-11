import Foundation

/// NA-04: the Niri animation names. Each has its own `[animations.<name>]`
/// table whose keys override the global `[animations]` values.
public enum AnimationKind: String, CaseIterable, Equatable, Hashable, Sendable {
    /// The viewport scrolls (focus changes, centering).
    case horizontalViewMovement = "horizontal-view-movement"
    /// Windows move in the layout (move column/window, consume/expel, and
    /// passive reflows such as a restore or a config reload).
    case windowMovement = "window-movement"
    /// Windows leave or enter through the bottom edge (NC-07).
    case workspaceSwitch = "workspace-switch"
    /// A new window rises into its column (NA-02).
    case windowOpen = "window-open"
    /// The neighbours close the gap of a closed window, and its ghost (NA-03).
    case windowClose = "window-close"
    /// Maximize, fullscreen and width changes, native zoom neighbours included.
    case windowResize = "window-resize"

    public var tableName: String { "animations.\(rawValue)" }
}

/// NA-04: what one `[animations.<name>]` table sets; nil inherits.
public struct AnimationOverride: Equatable, Sendable {
    public var enabled: Bool?
    public var curve: MotionCurveKind?
    public var springDampingRatio: Double?
    public var springStiffness: Double?
    public var durationMilliseconds: Int?

    public init(
        enabled: Bool? = nil, curve: MotionCurveKind? = nil, springDampingRatio: Double? = nil,
        springStiffness: Double? = nil, durationMilliseconds: Int? = nil
    ) {
        self.enabled = enabled
        self.curve = curve
        self.springDampingRatio = springDampingRatio
        self.springStiffness = springStiffness
        self.durationMilliseconds = durationMilliseconds
    }

    public var isEmpty: Bool { self == AnimationOverride() }

    /// Sets its own timing (curve or any of its parameters).
    public var hasCustomTiming: Bool {
        curve != nil || springDampingRatio != nil || springStiffness != nil || durationMilliseconds != nil
    }
}

/// NA-04: one animation's effective settings.
public struct ResolvedAnimation: Equatable, Sendable {
    public var enabled: Bool
    public var curve: MotionCurveKind
    public var spring: SpringParameters
    public var durationMilliseconds: Int

    public var duration: TimeInterval { TimeInterval(durationMilliseconds) / 1000 }
    /// Same rule as the global table: off or 0 ms is instant.
    public var isActive: Bool { enabled && durationMilliseconds > 0 }
}

extension AnimationsSectionConfig {
    /// NA-04: the global values with the kind's overrides on top. The global
    /// `enabled = false` turns every animation off; a kind's own
    /// `enabled = false` turns only that one off.
    public func resolved(_ kind: AnimationKind) -> ResolvedAnimation {
        let custom = overrides[kind] ?? AnimationOverride()
        return ResolvedAnimation(
            enabled: enabled && (custom.enabled ?? true),
            curve: custom.curve ?? curve,
            spring: SpringParameters(
                dampingRatio: custom.springDampingRatio ?? springDampingRatio,
                stiffness: custom.springStiffness ?? springStiffness,
                epsilon: SpringParameters.niri.epsilon
            ),
            durationMilliseconds: custom.durationMilliseconds ?? durationMilliseconds
        )
    }
}

/// NA-04: what triggered a layout pass, which picks the animation settings
/// of the whole pass. Windows that open (entries) and windows that cross
/// the bottom edge (workspace switch) keep their own kind whatever the cause.
public enum MotionCause: Equatable, Sendable {
    case viewScroll
    case windowMovement
    case workspaceSwitch
    case windowResize
    case windowOpen
    case windowClose
    /// No explicit trigger (restore, config reload, display change, drag snap-back).
    case passive

    public var kind: AnimationKind {
        switch self {
        case .viewScroll: return .horizontalViewMovement
        case .windowMovement, .passive: return .windowMovement
        case .workspaceSwitch: return .workspaceSwitch
        case .windowResize: return .windowResize
        case .windowOpen: return .windowOpen
        case .windowClose: return .windowClose
        }
    }

    /// Coalesced causes keep the dominant one: user actions outrank window
    /// events, a workspace switch outranks a resize, which outranks a move,
    /// which outranks a scroll.
    var rank: Int {
        switch self {
        case .passive: return 0
        case .windowOpen: return 1
        case .windowClose: return 2
        case .viewScroll: return 3
        case .windowMovement: return 4
        case .windowResize: return 5
        case .workspaceSwitch: return 6
        }
    }
}

/// NA-04: the triggering motion of a hotkey or IPC action. Exhaustive: a new
/// `HotkeyAction` case fails to compile here until it is classified.
public func motionCause(for action: HotkeyAction) -> MotionCause {
    switch action {
    case .focusLeft, .focusRight, .focusUp, .focusDown, .centerColumn,
         .focusColumnFirst, .focusColumnLast, .centerVisibleColumns,
         // MM-06: usually a scroll; crossing to a display moves no window.
         .focusColumnOrMonitorLeft, .focusColumnOrMonitorRight:
        return .viewScroll
    case .moveLeft, .moveRight, .moveUp, .moveDown, .moveColumnLeft, .moveColumnRight,
         .consumeOrExpelLeft, .consumeOrExpelRight, .toggleFloating,
         .moveColumnToMonitor, .moveWindowToMonitor,
         .moveColumnLeftOrToMonitorLeft, .moveColumnRightOrToMonitorRight,
         .moveColumnToFirst, .moveColumnToLast, .swapWindowLeft, .swapWindowRight:
        // MM-02: windows crossing to another display move like any window.
        return .windowMovement
    case .workspace, .moveToWorkspace, .focusWorkspaceDown, .focusWorkspaceUp,
         .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp,
         .focusMonitor, .moveWorkspaceToMonitor,
         .moveColumnToWorkspace, .moveColumnToWorkspaceDown, .moveColumnToWorkspaceUp,
         .focusWorkspacePrevious, .moveWorkspaceDown, .moveWorkspaceUp,
         // A move within the column does not scroll; only the switch animates.
         .focusWindowOrWorkspaceDown, .focusWindowOrWorkspaceUp:
        return .workspaceSwitch
    case .fullscreen, .switchPresetColumnWidth, .shrinkColumnWidth, .growColumnWidth, .maximizeColumn,
         .switchPresetWindowHeight, .shrinkWindowHeight, .growWindowHeight, .resetWindowHeight,
         .switchPresetColumnWidthBack, .expandColumnToAvailableWidth:
        return .windowResize
    case .toggleOverview:
        // The app opens a panel; nothing moves.
        return .passive
    }
}

/// NA-04: the cause of the next pass, noted by actions and window events
/// and taken by the pass that runs (deferred and coalesced passes included).
public struct MotionCauseLatch: Sendable {
    private var cause: MotionCause = .passive

    public init() {}

    public mutating func note(_ next: MotionCause) {
        if next.rank > cause.rank {
            cause = next
        }
    }

    public mutating func take() -> MotionCause {
        defer { cause = .passive }
        return cause
    }
}

/// NA-04: each animated window's kind: new windows enter as `window-open`,
/// windows crossing the bottom edge as `workspace-switch`, every other one
/// follows the pass's triggering cause.
public func classifyAnimationKinds(
    _ ids: some Sequence<WindowID>, cause: MotionCause, opening: Set<WindowID>, switching: Set<WindowID>
) -> [WindowID: AnimationKind] {
    var kinds: [WindowID: AnimationKind] = [:]
    for id in ids {
        if opening.contains(id) {
            kinds[id] = .windowOpen
        } else if switching.contains(id) {
            kinds[id] = .workspaceSwitch
        } else {
            kinds[id] = cause.kind
        }
    }
    return kinds
}
