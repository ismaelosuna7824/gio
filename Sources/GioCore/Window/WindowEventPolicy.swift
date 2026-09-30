import CoreGraphics
import Foundation

/// Typed window-level events raised by the accessibility layer.
public enum WindowEventKind: Equatable, Sendable {
    case windowCreated
    case focusedWindowChanged
    case moved
    case resized
    case miniaturized
    case deminiaturized
    case titleChanged
    case destroyed

    /// Maps an `AXObserver` notification name; nil for anything unwatched.
    public init?(axNotification name: String) {
        switch name {
        case "AXWindowCreated": self = .windowCreated
        case "AXFocusedWindowChanged": self = .focusedWindowChanged
        case "AXWindowMoved": self = .moved
        case "AXWindowResized": self = .resized
        case "AXWindowMiniaturized": self = .miniaturized
        case "AXWindowDeminiaturized": self = .deminiaturized
        case "AXTitleChanged": self = .titleChanged
        case "AXUIElementDestroyed": self = .destroyed
        default: return nil
        }
    }
}

/// What the session should do about one window event.
public enum WindowEventAction: Equatable, Sendable {
    /// Classify the element, register it if admitted, reflow now.
    case register
    /// Drop exactly this window everywhere, reflow now.
    case remove
    /// Geometry changed: unless it echoes our own write, optionally
    /// re-probe tileability for this window only, then reflow.
    case frameChanged(invalidateTileability: Bool)
    /// Reflow for this window's state change.
    case reflow
    /// Known window minimized: keep it registered, out of the layout.
    case minimize
    /// Known window deminimized: back into its column, focused.
    case restore
    case updateTitle
    /// The app's focused window changed (a click, a key switch): adopt it
    /// as the session focus on a light path, no rescan.
    case adoptFocus
    /// Fall back to the debounced full resync.
    case resync
    case ignore
}

/// Pure routing table: event kind plus whether the element is already a
/// registered window -> action.
public func windowEventAction(for kind: WindowEventKind, isKnownWindow: Bool) -> WindowEventAction {
    switch kind {
    case .windowCreated:
        return isKnownWindow ? .ignore : .register
    case .destroyed:
        return isKnownWindow ? .remove : .ignore
    case .moved:
        return isKnownWindow ? .frameChanged(invalidateTileability: false) : .ignore
    case .resized:
        return isKnownWindow ? .frameChanged(invalidateTileability: true) : .ignore
    case .miniaturized:
        return isKnownWindow ? .minimize : .ignore
    case .deminiaturized:
        return isKnownWindow ? .restore : .register
    case .titleChanged:
        return isKnownWindow ? .updateTitle : .ignore
    case .focusedWindowChanged:
        return .adoptFocus
    }
}

/// PA-04: while a motion writes frames for an app, that app's moved/resized
/// events are our own echoes. Dropping them before the handle lookup and the
/// echo gate keeps a burst of AX events from costing anything per event.
public func dropsAsMotionEcho(_ kind: WindowEventKind, pid: pid_t, animating: Set<pid_t>) -> Bool {
    guard !animating.isEmpty, animating.contains(pid) else {
        return false
    }
    return kind == .moved || kind == .resized
}

/// Breaks the write -> event -> reflow -> write loop. The reconciler's own
/// frame writes raise moved/resized events; an event is an echo when the
/// window now sits at the frame we last applied (within tolerance), or when
/// it arrives within a short window after our write (a window clamped to a
/// minimum size never matches, but must not retrigger us either). Time is
/// injected so the rule stays deterministic.
public struct WriteEchoGate: Sendable {
    public static let tolerance: CGFloat = 2
    public static let suppression: TimeInterval = 0.35

    private struct Entry: Sendable {
        let frame: CGRect
        let at: TimeInterval
    }

    private var entries: [WindowID: Entry] = [:]

    public init() {}

    public mutating func recordApplied(_ frames: [WindowID: CGRect], at time: TimeInterval) {
        for (id, frame) in frames {
            entries[id] = Entry(frame: frame, at: time)
        }
    }

    /// Single-window form for the per-tick path: no dictionary is built.
    public mutating func recordApplied(_ id: WindowID, frame: CGRect, at time: TimeInterval) {
        entries[id] = Entry(frame: frame, at: time)
    }

    public mutating func forget(_ id: WindowID) {
        entries.removeValue(forKey: id)
    }

    /// Inside the suppression window after our own write to `id`: the event
    /// is an echo whatever the window reports, so callers can skip the
    /// Accessibility read that `isEcho` needs (animation frames raise many).
    public func isSuppressed(_ id: WindowID, at time: TimeInterval) -> Bool {
        guard let entry = entries[id] else {
            return false
        }
        return time - entry.at <= Self.suppression
    }

    public func isEcho(_ id: WindowID, observed: CGRect, at time: TimeInterval) -> Bool {
        guard let entry = entries[id] else {
            return false
        }
        if time - entry.at <= Self.suppression {
            return true
        }
        let tolerance = Self.tolerance
        return abs(observed.origin.x - entry.frame.origin.x) <= tolerance
            && abs(observed.origin.y - entry.frame.origin.y) <= tolerance
            && abs(observed.width - entry.frame.width) <= tolerance
            && abs(observed.height - entry.frame.height) <= tolerance
    }
}

/// PF-02: why a new window could not be classified yet.
public enum WindowRegistrationFailure: String, Equatable, Sendable {
    /// Only its frame is not readable yet: it is a window a moment away.
    case frameUnreadable
    /// Ignored by admission, untrusted, or unknown (the original schedule).
    case unclassified
}

/// A new window's attributes are often not readable in the very first
/// moments; classification is retried a few times with short delays.
/// PF-02: an element whose frame alone is unreadable retries sooner.
public enum WindowRegistrationRetry {
    public static let delays: [TimeInterval] = [0.1, 0.3, 0.8]
    public static let frameUnreadableDelays: [TimeInterval] = [0.03, 0.08, 0.2, 0.5]
    public static var maxRetries: Int { delays.count }

    public static func delay(
        afterFailedAttempt attempt: Int, reason: WindowRegistrationFailure = .unclassified
    ) -> TimeInterval? {
        let schedule = reason == .frameUnreadable ? frameUnreadableDelays : delays
        guard attempt >= 0, attempt < schedule.count else {
            return nil
        }
        return schedule[attempt]
    }
}
