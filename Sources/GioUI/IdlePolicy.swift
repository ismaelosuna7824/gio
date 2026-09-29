import Foundation

/// PA-02 idle policy: Gio does no periodic work while nobody looks at it.
/// A UI ticker runs only while the main window is visible and its section
/// is on screen.
public func shouldPoll(windowVisible: Bool, sectionOnScreen: Bool) -> Bool {
    windowVisible && sectionOnScreen
}

/// Drops repeats so the menu bar only redraws when the session state
/// really changed (pushed by the session on every reflow).
public struct BarStateGate: Sendable {
    private var last: BarSessionState??

    public init() {}

    public mutating func accept(_ state: BarSessionState?) -> Bool {
        if let last, last == state {
            return false
        }
        last = .some(state)
        return true
    }
}
