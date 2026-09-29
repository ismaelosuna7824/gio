import Foundation

extension HotkeyAction {
    /// Keyboard actions after which the OS keyboard focus must follow Gio's
    /// logical focus. Sizing, centering and floating toggles act on the window
    /// the user is already typing into, so they never move focus.
    public var carriesFocusIntent: Bool {
        switch self {
        case .focusLeft, .focusRight, .focusUp, .focusDown,
             .moveLeft, .moveRight, .moveUp, .moveDown,
             .workspace, .moveToWorkspace, .fullscreen,
             .focusWorkspaceDown, .focusWorkspaceUp,
             .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp,
             .consumeOrExpelLeft, .consumeOrExpelRight:
            return true
        case .toggleFloating, .switchPresetColumnWidth, .shrinkColumnWidth,
             .growColumnWidth, .maximizeColumn, .centerColumn:
            return false
        }
    }
}

extension CLICommand {
    /// IPC commands that change the logical focus deliberately.
    public var carriesFocusIntent: Bool {
        switch self {
        case .focus, .move, .workspace:
            return true
        default:
            return false
        }
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

    public init() {}

    /// Record the window to focus (nil: nothing to focus, drop any stale one).
    public mutating func request(_ id: WindowID?, now: TimeInterval) {
        pending = id
        expected = id
        expectedUntil = now + Self.requestWindow
    }

    /// A user click overrides whatever was pending.
    public mutating func cancel() {
        pending = nil
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

    /// True for a non-click focus adoption that contradicts the window we are
    /// about to focus or just focused: a trailing event of the previous focus.
    public func shouldIgnoreAdoption(of id: WindowID, now: TimeInterval) -> Bool {
        guard let expected, now <= expectedUntil else {
            return false
        }
        return expected != id
    }
}
