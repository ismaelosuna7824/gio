import Foundation

extension HotkeyAction {
    /// Keyboard actions after which the OS keyboard focus must follow Gio's
    /// logical focus. Sizing, centering and floating toggles act on the window
    /// the user is already typing into, so they never move focus.
    public var carriesFocusIntent: Bool {
        switch self {
        case .focusLeft, .focusRight, .focusUp, .focusDown,
             .moveLeft, .moveRight, .moveUp, .moveDown,
             .moveColumnLeft, .moveColumnRight,
             .workspace, .moveToWorkspace, .fullscreen,
             .focusWorkspaceDown, .focusWorkspaceUp,
             .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp,
             .consumeOrExpelLeft, .consumeOrExpelRight,
             .focusMonitor, .moveColumnToMonitor, .moveWindowToMonitor, .moveWorkspaceToMonitor,
             .focusColumnFirst, .focusColumnLast, .moveColumnToFirst, .moveColumnToLast,
             .swapWindowLeft, .swapWindowRight,
             .moveColumnToWorkspace, .moveColumnToWorkspaceDown, .moveColumnToWorkspaceUp,
             .focusWorkspacePrevious, .focusWindowOrWorkspaceDown, .focusWindowOrWorkspaceUp,
             .moveColumnLeftOrToMonitorLeft, .moveColumnRightOrToMonitorRight,
             .focusColumnOrMonitorLeft, .focusColumnOrMonitorRight:
            return true
        case .toggleFloating, .switchPresetColumnWidth, .shrinkColumnWidth,
             .growColumnWidth, .maximizeColumn, .centerColumn, .toggleOverview,
             .switchPresetWindowHeight, .shrinkWindowHeight, .growWindowHeight, .resetWindowHeight,
             .switchPresetColumnWidthBack, .expandColumnToAvailableWidth, .centerVisibleColumns:
            return false
        case .moveWorkspaceDown, .moveWorkspaceUp:
            // The shown workspace and its focused window stay the same; only
            // the stack order changes.
            return false
        case .toggleWorkspaceLayout, .setWorkspaceLayout, .dwindleToggleSplit, .dwindleSwapSplit,
             .dwindleBalance, .dwindlePreselect, .dwindlePreselectClear:
            // DW-02: the windows rearrange; the focused window stays focused.
            return false
        }
    }
}

extension HotkeyAction {
    /// Sizing actions that resize the window the user is already typing into
    /// (no focus change, so no `FocusIntent`). The session treats that window
    /// as the focused-grow target: it is already frontmost. Fullscreen carries
    /// a focus intent instead.
    public var growsFocusedWindow: Bool {
        switch self {
        case .switchPresetColumnWidth, .growColumnWidth, .shrinkColumnWidth, .maximizeColumn,
             .switchPresetWindowHeight, .growWindowHeight, .shrinkWindowHeight, .resetWindowHeight,
             .switchPresetColumnWidthBack, .expandColumnToAvailableWidth:
            return true
        default:
            return false
        }
    }
}

extension CLICommand {
    /// IPC commands that change the logical focus deliberately.
    public var carriesFocusIntent: Bool {
        switch self {
        case .focus, .move, .workspace, .moveWindowToDisplay:
            return true
        default:
            return false
        }
    }
}

/// FI-06: why the final pass focuses the delivered target again.
public enum FocusReassertReason: String, Equatable, Sendable {
    case otherApp
    case sameAppDrift
    case unreadable
}

/// FI-06: a decision to re-assert keyboard focus on `id`.
public struct FocusReassert: Equatable, Sendable {
    public let id: WindowID
    public let reason: FocusReassertReason

    public init(id: WindowID, reason: FocusReassertReason) {
        self.id = id
        self.reason = reason
    }
}

/// HD-01: what the session wants the OS to focus, and the guard that keeps
/// Gio's own focus change from echoing back as a user change.
///
/// A keyboard/IPC action `request`s a target. Passive reflows (AX events,
/// click adoption, reloads, rescans) never request one, so they hand the
/// reconciler `focused: nil`. While an animation is starting the target is
/// held back (`take` returns nil) and released on the final exact pass.
/// Session queue only; no locking.
public struct FocusIntent: Equatable, Sendable {
    /// How long a fresh request shields the intended window (covers motion).
    public static let requestWindow: TimeInterval = 2
    /// How long after the focus call app activation events may still trail.
    public static let settleWindow: TimeInterval = 0.6

    private var pending: WindowID?
    private var expected: WindowID?
    private var expectedUntil: TimeInterval = 0
    /// FI-06: the target already focused at motion start, kept so the final
    /// exact pass can re-assert it if focus drifted.
    private var delivered: WindowID?

    public init() {}

    /// Record the window to focus (nil: nothing to focus, drop any stale one).
    public mutating func request(_ id: WindowID?, now: TimeInterval) {
        pending = id
        delivered = nil
        expected = id
        expectedUntil = now + Self.requestWindow
    }

    /// A user click overrides whatever was pending.
    public mutating func cancel() {
        pending = nil
        delivered = nil
        expected = nil
    }

    /// The id to give the reconciler for this pass. Held while `motionStarting`
    /// (the final exact pass owns focus); never handed out when parked.
    public mutating func take(motionStarting: Bool, parked: Set<WindowID>, now: TimeInterval) -> WindowID? {
        guard !motionStarting, let target = pending else {
            return nil
        }
        pending = nil
        guard !parked.contains(target) else {
            expected = nil
            return nil
        }
        expected = target
        expectedUntil = now + Self.settleWindow
        return target
    }

    /// The target `takeImmediate` would hand out, without consuming it (nil
    /// when nothing is pending or it is parked). The motion planner uses it to
    /// know which window the keyboard is about to raise.
    public func pendingTarget(parked: Set<WindowID>) -> WindowID? {
        guard let pending, !parked.contains(pending) else {
            return nil
        }
        return pending
    }

    /// FI-06: the target for an immediate focus call at motion start (the
    /// keyboard follows the logical focus without waiting for the animation).
    /// Never handed out when parked; remembered for `takeReassert`.
    public mutating func takeImmediate(parked: Set<WindowID>, now: TimeInterval) -> WindowID? {
        guard let target = take(motionStarting: false, parked: parked, now: now) else {
            return nil
        }
        delivered = target
        return target
    }

    /// FI-06: on the final exact pass, the target to focus again, decided with
    /// full information: another app is frontmost, or the frontmost app (the
    /// target's own) keeps a different window focused, or that window cannot
    /// be read (fail towards the user's intent). `frontmostFocusedWindow` is
    /// only called for a same-app check; nil means unreadable/unresolvable.
    /// Consumed once (no loops); a click or a new request clears it.
    public mutating func takeReassert(
        logicalFocus: WindowID?,
        frontmostPID: pid_t?,
        frontmostFocusedWindow: () -> WindowID?
    ) -> FocusReassert? {
        defer { delivered = nil }
        guard let target = delivered, target == logicalFocus else {
            return nil
        }
        guard frontmostPID == target.pid else {
            return FocusReassert(id: target, reason: .otherApp)
        }
        guard let focused = frontmostFocusedWindow() else {
            return FocusReassert(id: target, reason: .unreadable)
        }
        return focused == target ? nil : FocusReassert(id: target, reason: .sameAppDrift)
    }

    /// True for a non-click focus adoption that contradicts the window we are
    /// about to focus or just focused: a trailing event of the previous focus.
    public func shouldIgnoreAdoption(of id: WindowID, now: TimeInterval) -> Bool {
        guard let expected, now <= expectedUntil else {
            return false
        }
        return expected != id
    }
}
