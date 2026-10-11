import CoreGraphics
import Foundation

/// Where a column moved to another workspace lands in the target strip.
public enum ColumnLanding: Equatable, Sendable {
    /// Right after the target's focused column (first when it is empty):
    /// `move-column-to-monitor-*`, `move-column-to-workspace*`.
    case afterFocused
    /// MM-06: the first column (entering from the left edge).
    case first
    /// MM-06: the last column (entering from the right edge).
    case last
}

/// MM-06: what an edge-crossing action did.
public enum EdgeStep: Equatable, Sendable {
    /// Nothing: no column / window that way and no display past the edge.
    case unchanged
    /// The move or focus stayed in the current workspace.
    case withinWorkspace
    /// The column or focus went to the neighbouring display (the caller
    /// syncs the shown workspace).
    case crossedDisplay
}

extension WorkspaceManager {
    /// MM-06 niri `move-column-left-or-to-monitor-left` / `-right-or-to-monitor-right`
    /// (and `move-column-left/right` with `move-crosses-monitor-at-edge`):
    /// the in-strip column move; when the column already sits at the strip's
    /// edge, it goes to the display next to the focused one that way
    /// (`displayNeighbour` over `frames`) and enters by the edge it crossed:
    /// moving right it becomes the target's first column, moving left its
    /// last. Focus follows; the target display's reveal then scrolls to it.
    /// Horizontal directions only; anything else is `.unchanged`.
    /// DW-02: on a dwindle workspace the in-workspace step is `dwindleMove`
    /// (a swap with the geometric neighbour, measured with `geometry`), and
    /// its `.atEdge` crosses: the focused window (its own column in dwindle)
    /// moves to the neighbouring display.
    @discardableResult
    public mutating func moveColumnOrToDisplay(
        _ direction: FocusDirection, frames: [DisplayID: CGRect], geometry: DwindleGeometry? = nil
    ) -> EdgeStep {
        guard direction == .left || direction == .right else {
            return .unchanged
        }
        let workspace = currentWorkspace()
        if workspace.layout == .dwindle {
            switch dwindleMove(in: workspace, direction: direction, geometry: geometry ?? .fallback(frames[focusedDisplay])) {
            case .moved(let next):
                update(next)
                return .withinWorkspace
            case .unchanged:
                return .unchanged
            case .atEdge:
                break
            }
        } else {
            // Qualified: the manager's own `moveColumn(toDisplay:)` shadows it.
            let moved = GioCore.moveColumn(in: workspace, direction: direction)
            if moved != workspace {
                update(moved)
                return .withinWorkspace
            }
        }
        guard let target = displayNeighbour(of: focusedDisplay, direction: direction, frames: frames),
              moveColumn(toDisplay: target, landing: direction == .right ? .first : .last)
        else {
            return .unchanged
        }
        return .crossedDisplay
    }

    /// MM-06 niri `focus-column-or-monitor-left` / `-right`: focus the
    /// neighbouring column, or from the strip's edge (or an empty workspace)
    /// the display next to the focused one that way, with its own focused
    /// column. Horizontal directions only. DW-02: in dwindle, the geometric
    /// neighbour (`dwindleFocus`), and the display from the tree's edge.
    @discardableResult
    public mutating func focusColumnOrDisplay(
        _ direction: FocusDirection, frames: [DisplayID: CGRect], geometry: DwindleGeometry? = nil
    ) -> EdgeStep {
        guard direction == .left || direction == .right else {
            return .unchanged
        }
        let workspace = currentWorkspace()
        let focused = focusNeighbour(
            in: workspace, direction: direction, geometry: geometry ?? .fallback(frames[focusedDisplay])
        )
        if focused != workspace {
            update(focused)
            return .withinWorkspace
        }
        guard let target = displayNeighbour(of: focusedDisplay, direction: direction, frames: frames),
              focusDisplay(target)
        else {
            return .unchanged
        }
        return .crossedDisplay
    }
}
