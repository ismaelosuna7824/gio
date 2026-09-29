import CoreGraphics
import Foundation

/// `mouse-follows-focus`: where to put the cursor after a keyboard focus
/// change (Cocoa coordinates). Nil when the option is off, the frame is
/// empty, or the pointer already rests inside the focused window.
public func mouseFollowsFocusTarget(enabled: Bool, frame: CGRect, pointer: CGPoint) -> CGPoint? {
    guard enabled, !frame.isEmpty, !frame.contains(pointer) else {
        return nil
    }
    return CGPoint(x: frame.midX, y: frame.midY)
}

/// Cocoa (bottom-left origin) to the global display space CoreGraphics warps
/// in (top-left origin of the primary display).
public func globalDisplayPoint(fromCocoa point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: primaryHeight - point.y)
}

/// `focus-follows-mouse`: the managed, visible window the pointer is over.
/// `topWindowPID` is the owner of the frontmost real window at the point, so
/// a foreign or Gio-owned window covering a managed one blocks the hover.
public func hoverTarget(
    at point: CGPoint, frames: [WindowID: CGRect], topWindowPID: pid_t?, ownPID: pid_t
) -> WindowID? {
    guard let topWindowPID, topWindowPID != ownPID else {
        return nil
    }
    return frames
        .filter { $0.key.pid == topWindowPID && $0.value.contains(point) }
        .min { ($0.key.pid, $0.key.elementID) < ($1.key.pid, $1.key.elementID) }?
        .key
}

/// Debounce for `focus-follows-mouse`: the pointer must rest over one window
/// for `restDelay` before it takes focus; a cursor warp from
/// `mouse-follows-focus` silences hover for `warpSuppression` so the two
/// options never loop. Session queue only; no locking.
public struct HoverFocus: Equatable, Sendable {
    public static let restDelay: TimeInterval = 0.1
    public static let warpSuppression: TimeInterval = 0.4

    private var candidate: WindowID?
    private var since: TimeInterval = 0
    private var suppressedUntil: TimeInterval = -1
    private var blocked = false

    public init() {}

    /// The pointer is over `target` (nil: nothing manageable). Returns the
    /// delay after which the caller should ask `due`, or nil when no check
    /// needs scheduling.
    public mutating func pointerMoved(over target: WindowID?, now: TimeInterval) -> TimeInterval? {
        guard now >= suppressedUntil, let target else {
            candidate = nil
            return nil
        }
        if candidate == target {
            guard blocked else {
                return nil
            }
            blocked = false
            since = now
            return Self.restDelay
        }
        candidate = target
        since = now
        blocked = false
        return Self.restDelay
    }

    /// The window to focus now, if the pointer rested long enough, no mouse
    /// button is down, and it is not already the focused window.
    public mutating func due(now: TimeInterval, buttonDown: Bool, focused: WindowID?) -> WindowID? {
        guard let target = candidate, now >= suppressedUntil else {
            return nil
        }
        if buttonDown {
            blocked = true
            return nil
        }
        guard now - since >= Self.restDelay - 0.000_001 else {
            return nil
        }
        candidate = nil
        return target == focused ? nil : target
    }

    /// Gio moved the cursor itself: ignore hover until it settles.
    public mutating func noteWarp(now: TimeInterval) {
        suppressedUntil = now + Self.warpSuppression
        candidate = nil
        blocked = false
    }
}
