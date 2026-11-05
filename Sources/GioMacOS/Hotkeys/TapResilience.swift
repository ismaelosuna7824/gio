import CoreGraphics
import Foundation
import GioCore

/// Why the tap had to be switched back on.
enum TapReenableReason: String, Equatable {
    case timeout
    case userInput
    case watchdog
}

/// What the tap callback does with one event type.
enum TapEventAction: Equatable {
    case reenable(TapReenableReason)
    case mouseDown
    case mouseMoved
    case keyDown
    /// TG-10: swallowed while tap-to-swipe is armed.
    case scrollWheel
    case passThrough
}

/// macOS delivers `tapDisabledBy*` to the callback when it turns the tap off
/// (callback too slow, or user input). Those events must re-enable the tap and
/// never be treated as keys.
func tapEventAction(for type: CGEventType) -> TapEventAction {
    switch type {
    case .tapDisabledByTimeout: return .reenable(.timeout)
    case .tapDisabledByUserInput: return .reenable(.userInput)
    case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .mouseDown
    case .mouseMoved: return .mouseMoved
    case .keyDown: return .keyDown
    case .scrollWheel: return .scrollWheel
    default: return .passThrough
    }
}

/// The tap's optional event types: each costs a tap callback per event, so
/// each is subscribed only while a setting needs it.
public struct TapSubscriptions: Equatable, Sendable {
    /// Pointer moves: focus-follows-mouse.
    public var mouseMoved: Bool
    /// TG-10: scroll events, swallowed while tap-to-swipe is armed.
    public var scrollWheel: Bool

    public init(mouseMoved: Bool = false, scrollWheel: Bool = false) {
        self.mouseMoved = mouseMoved
        self.scrollWheel = scrollWheel
    }
}

/// Keys and clicks always; pointer moves and scroll events only while
/// subscribed, so an idle setting costs no callbacks per move or scroll.
func tapEventMask(_ subscriptions: TapSubscriptions) -> CGEventMask {
    var types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    if subscriptions.mouseMoved {
        types.append(.mouseMoved)
    }
    if subscriptions.scrollWheel {
        types.append(.scrollWheel)
    }
    return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
}

/// A live tap only needs rebuilding when its optional subscriptions differ
/// from what the config wants now.
public func tapNeedsRestart(current: TapSubscriptions, wanted: TapSubscriptions) -> Bool {
    current != wanted
}

/// TG-10: a scroll event is swallowed only when the handler (an armed
/// tap-to-swipe) says so.
func tapSwallowsScroll(handler: (() -> Bool)?) -> Bool {
    handler?() ?? false
}

enum TapWatchdogAction: Equatable {
    case none
    case reenable
}

/// Belt and braces for disables macOS never announces.
func tapWatchdogAction(isEnabled: Bool) -> TapWatchdogAction {
    isEnabled ? .none : .reenable
}

/// Counts re-enables: the first is a warning (something is slow), the rest are
/// debug so a flapping tap cannot flood the log.
struct TapReenableTracker {
    private(set) var count = 0

    mutating func record(_ reason: TapReenableReason) -> (level: LogLevel, message: String) {
        count += 1
        return (
            count == 1 ? .warn : .debug,
            "hotkey tap re-enabled after \(reason.rawValue) (count=\(count))"
        )
    }
}
