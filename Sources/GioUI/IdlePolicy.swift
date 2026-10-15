import Foundation

/// PA-02 idle policy: Gio does no periodic work while nobody looks at it.
/// A UI ticker runs only while the main window is visible and its section
/// is on screen.
public func shouldPoll(windowVisible: Bool, sectionOnScreen: Bool) -> Bool {
    windowVisible && sectionOnScreen
}

/// PF-AG: Gio's own flight overlay covers the main window for the length of
/// a slide, which flipped its occlusion state twice per action and made the
/// whole SwiftUI window re-render each time. Being covered counts only once
/// it lasted `hideDelay`; coming into view counts at once.
public struct OcclusionGate: Sendable {
    public static let hideDelay: TimeInterval = 1

    private var generation = 0
    private var covered = false

    public init() {}

    /// The window is covered: ask `shouldHide` with the token after
    /// `hideDelay`.
    public mutating func occluded() -> Int {
        generation += 1
        covered = true
        return generation
    }

    public mutating func uncovered() {
        generation += 1
        covered = false
    }

    public func shouldHide(_ token: Int) -> Bool {
        covered && token == generation
    }
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
