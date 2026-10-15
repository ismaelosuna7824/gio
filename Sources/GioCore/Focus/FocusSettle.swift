import CoreGraphics
import Foundation

/// Timings for click-driven focus adoption. On a click the activation and
/// focused-window events can outrun the app's own `AXFocusedWindow`, so the
/// host waits for the button to come up and the app to settle.
public enum FocusTiming {
    /// A mouse-down this recent still explains a focus event.
    public static let recentClickWindow: TimeInterval = 0.3
    /// Quiet time after the button is released before the focus is read.
    public static let settleDelay: TimeInterval = 0.08
    /// Delay before the single re-read of a focus that did not match.
    public static let retryDelay: TimeInterval = 0.1
    public static let pollInterval: TimeInterval = 0.02
    /// Slack for a click on a window's very edge.
    public static let hitTolerance: CGFloat = 2
}

/// What raised a focus adoption (diagnostics only).
public enum FocusSource: String, Sendable {
    case activation
    case focusChanged
    case rescan
    /// `focus-follows-mouse`: the pointer rested over the window.
    case hover
}

/// A mouse-down: where (Cocoa global coordinates, the frames' space) and
/// when (system uptime). WC-13: `onSystemUI` once the session learned the
/// click landed on the Dock or the menu bar (`clickIsOnSystemUI`).
public struct MouseClick: Equatable, Sendable {
    public let location: CGPoint
    public let time: TimeInterval
    public var onSystemUI: Bool

    public init(location: CGPoint, time: TimeInterval, onSystemUI: Bool = false) {
        self.location = location
        self.time = time
        self.onSystemUI = onSystemUI
    }
}

/// WC-13: a window under a click point, front to back, in the same space
/// as the point.
public struct PointWindow: Equatable, Sendable {
    public let pid: pid_t
    public let layer: Int
    public let bounds: CGRect

    public init(pid: pid_t, layer: Int, bounds: CGRect) {
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
    }
}

/// WC-13: the Dock's window layer (`kCGDockWindowLevel`); the menu bar,
/// status items and menus are above it.
public let systemUIWindowLayer = 20

/// WC-13: whether a click at `point` landed on the Dock or the menu bar: the
/// frontmost window under it, skipping Gio's own click-through panels (ring,
/// dim, overlay), is at the Dock's layer or above. App windows, app panels
/// below the Dock and the desktop are not system UI.
public func clickIsOnSystemUI(at point: CGPoint, frontToBack: [PointWindow], ownPID: pid_t) -> Bool {
    guard let top = frontToBack.first(where: { $0.pid != ownPID && $0.bounds.contains(point) }) else {
        return false
    }
    return top.layer >= systemUIWindowLayer
}

/// The click that explains a focus event happening `now`, or nil when the
/// event is keyboard-driven. `lastTapped` is the newest mouse-down seen by
/// the event tap; without a tap a pressed button still counts, using the
/// current pointer position.
public func recentClick(
    pressed: Bool, currentLocation: CGPoint, now: TimeInterval, lastTapped: MouseClick?
) -> MouseClick? {
    if let lastTapped, pressed || now - lastTapped.time <= FocusTiming.recentClickWindow {
        return lastTapped
    }
    return pressed ? MouseClick(location: currentLocation, time: now) : nil
}

/// Clicks on the menu bar or Dock (outside every display's usable area, or
/// WC-13: on them inside it, an auto-hidden Dock) activate apps without
/// pointing at a window: they are not window clicks.
public func windowAreaClick(_ click: MouseClick?, visibleAreas: [CGRect]) -> MouseClick? {
    guard let click, !click.onSystemUI, visibleAreas.contains(where: { $0.contains(click.location) }) else {
        return nil
    }
    return click
}

/// The focused window is the clicked one only if it is under the pointer.
public func focusMatchesClick(frame: CGRect?, click: CGPoint) -> Bool {
    guard let frame else {
        return false
    }
    let slack = FocusTiming.hitTolerance
    return frame.insetBy(dx: -slack, dy: -slack).contains(click)
}

/// Pure scheduling of focus adoption. Keyboard-driven events (no click)
/// adopt at once. Mouse-driven ones coalesce (last event wins), wait for the
/// release plus the settle delay, and then must match the click; a mismatch
/// is re-read once before the adoption is dropped. The host owns timers and
/// feeds it button state and clock.
public struct FocusSettle<Event: Equatable> {
    public enum Request: Equatable {
        case adoptNow(Event)
        case wait(after: TimeInterval)
        case coalesced
    }

    public enum Poll: Equatable {
        case idle
        case wait(after: TimeInterval)
        case resolve(Event, MouseClick)
    }

    public enum Verdict: Equatable {
        case adopt
        case retry(after: TimeInterval)
        case giveUp
    }

    private enum Phase {
        case idle
        case waiting(releasedAt: TimeInterval?)
        case verifying(attempt: Int)
    }

    private var phase = Phase.idle
    private var event: Event?
    private var click: MouseClick?

    public init() {}

    public mutating func request(_ new: Event, click newClick: MouseClick?) -> Request {
        if case .idle = phase {
            guard let newClick else {
                return .adoptNow(new)
            }
            event = new
            click = newClick
            phase = .waiting(releasedAt: nil)
            return .wait(after: FocusTiming.pollInterval)
        }
        event = new
        click = newClick ?? click
        return .coalesced
    }

    public mutating func poll(mouseDown: Bool, now: TimeInterval) -> Poll {
        guard case .waiting(let releasedAt) = phase, let event, let click else {
            return .idle
        }
        if mouseDown {
            phase = .waiting(releasedAt: nil)
            return .wait(after: FocusTiming.pollInterval)
        }
        guard let releasedAt else {
            phase = .waiting(releasedAt: now)
            return .wait(after: FocusTiming.pollInterval)
        }
        guard now - releasedAt >= FocusTiming.settleDelay else {
            return .wait(after: FocusTiming.pollInterval)
        }
        phase = .verifying(attempt: 1)
        return .resolve(event, click)
    }

    /// The host read the focused window and compared it with the click.
    public mutating func judge(matchesClick: Bool) -> Verdict {
        guard case .verifying(let attempt) = phase else {
            return .giveUp
        }
        if matchesClick {
            reset()
            return .adopt
        }
        if attempt < 2 {
            phase = .verifying(attempt: attempt + 1)
            return .retry(after: FocusTiming.retryDelay)
        }
        reset()
        return .giveUp
    }

    /// The event and click for the scheduled re-read, newest wins.
    public func resolveAgain() -> (Event, MouseClick)? {
        guard case .verifying = phase, let event, let click else {
            return nil
        }
        return (event, click)
    }

    public mutating func discard() {
        reset()
    }

    private mutating func reset() {
        phase = .idle
        event = nil
        click = nil
    }
}
