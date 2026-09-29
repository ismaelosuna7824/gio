import Foundation

/// Niri `center-focused-column`. Decides whether a keyboard focus change also
/// centers the newly focused column instead of scrolling minimally.
public enum CenterFocusedColumnMode: String, CaseIterable, Sendable {
    /// Minimal scroll: only bring the focused column into view.
    case never
    /// Center the focused column on every keyboard focus change.
    case always
    /// Center only when the focused column does not fit on screen together
    /// with the previously focused one; otherwise scroll minimally.
    case onOverflow = "on-overflow"

    /// Legacy boolean form of the key: `true` centered, `false` did not.
    public init(legacy enabled: Bool) {
        self = enabled ? .always : .never
    }
}

/// One reflow's centering request: the mode plus the column that had focus
/// before the change (what `on-overflow` measures against).
public struct CenterRequest: Equatable, Sendable {
    public var mode: CenterFocusedColumnMode
    public var previouslyFocused: WindowID?

    public init(mode: CenterFocusedColumnMode, previouslyFocused: WindowID?) {
        self.mode = mode
        self.previouslyFocused = previouslyFocused
    }

    /// Passive reflows never center: only minimal reveal.
    public static let none = CenterRequest(mode: .never, previouslyFocused: nil)
}
