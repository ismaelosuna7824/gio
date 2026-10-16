import Foundation

/// `[layout] new-window-position`: where a new window's column lands in a
/// scrolling workspace's strip, relative to the destination's focused column.
public enum NewWindowPosition: String, CaseIterable, Sendable {
    /// After the last column.
    case end
    /// Before the first column.
    case start
    /// Right after the focused column.
    case rightOfFocused = "right-of-focused"
    /// Right before the focused column.
    case leftOfFocused = "left-of-focused"

    /// The index the new column takes in a strip of `count` columns whose
    /// focused column is `focusedColumn`; 0 for an empty strip.
    public func insertionIndex(columnCount count: Int, focusedColumn: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        let focused = min(max(focusedColumn, 0), count - 1)
        switch self {
        case .end:
            return count
        case .start:
            return 0
        case .rightOfFocused:
            return focused + 1
        case .leftOfFocused:
            return focused
        }
    }
}
