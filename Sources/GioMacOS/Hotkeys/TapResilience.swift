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
    default: return .passThrough
    }
}

/// Keys and clicks always; pointer moves only for focus-follows-mouse, so an
/// idle setting costs no main-thread callbacks per mouse move.
func tapEventMask(observingMouseMoved: Bool) -> CGEventMask {
    var types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    if observingMouseMoved {
        types.append(.mouseMoved)
    }
    return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
}

/// A live tap only needs rebuilding when the mouse-move subscription differs
/// from what the config wants now.
public func tapNeedsRestart(observingMouseMoved: Bool, wanted: Bool) -> Bool {
    observingMouseMoved != wanted
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
