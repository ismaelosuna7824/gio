import CoreGraphics
import Foundation

// MM-01: pure display geometry. All frames are Cocoa (bottom-left origin,
// y up), the coordinates the session keeps.

/// The primary display: the one at the Cocoa origin (it holds the menu bar
/// and defines the global AX/WindowServer flip), else the first one. Nil
/// without displays. Never the key-window screen (`NSScreen.main`).
public func primaryDisplayIndex(_ frames: [CGRect]) -> Int? {
    frames.firstIndex { $0.origin == .zero } ?? (frames.isEmpty ? nil : 0)
}

/// Displays in position order: left to right, then top to bottom (higher
/// `maxY` first, Cocoa y grows up); identical positions fall back to the ID
/// so the order is total.
public func displaysByPosition(_ frames: [DisplayID: CGRect]) -> [DisplayID] {
    frames.keys.sorted { lhs, rhs in
        let (a, b) = (frames[lhs]!, frames[rhs]!)
        if a.minX != b.minX {
            return a.minX < b.minX
        }
        if a.maxY != b.maxY {
            return a.maxY > b.maxY
        }
        return lhs.rawValue < rhs.rawValue
    }
}

/// MM-04: the display numbers users see (`[[workspace]] display = N`, the
/// menu bar's Move to Display, `gio move-window-to-display N`, the
/// `display ... number=` log field): the primary display is 1, the others
/// follow in position order. Same numbering as `WorkspaceManager.display(numbered:)`.
public func displaysByNumber(_ frames: [DisplayID: CGRect]) -> [DisplayID] {
    let ordered = displaysByPosition(frames)
    guard let primary = primaryDisplayIndex(ordered.map { frames[$0]! }) else {
        return []
    }
    return [ordered[primary]] + ordered.enumerated().filter { $0.offset != primary }.map(\.element)
}

/// MM-04: why the overview opens on a display.
public enum OverviewDisplayReason: String, Equatable, Sendable {
    /// The display holding most of the focused window.
    case focusedWindow
    /// No focused window on a display: the one under the cursor.
    case cursor
    /// Neither: Gio's focused display.
    case focusedDisplay
}

/// MM-04: the display the overview (Alt+O) opens on, the one the user is on:
/// the display holding the largest share of the focused window, else the
/// display under the cursor, else Gio's focused display. Niri opens it on the
/// focused output; the focused window's display is that output whenever Gio
/// adopted the focus. Nil without displays.
public func overviewDisplay(
    focusedWindowFrame: CGRect?, cursor: CGPoint?, displays: [DisplayID: CGRect], focusedDisplay: DisplayID?
) -> (display: DisplayID, reason: OverviewDisplayReason)? {
    if let frame = focusedWindowFrame, let display = displayFor(frame: frame, displays: displays) {
        return (display, .focusedWindow)
    }
    if let cursor, let display = displaysByPosition(displays).first(where: { displays[$0]!.contains(cursor) }) {
        return (display, .cursor)
    }
    if let focusedDisplay, displays[focusedDisplay] != nil {
        return (focusedDisplay, .focusedDisplay)
    }
    return nil
}

/// The display holding the largest share of `frame` (an even split goes to
/// the first display in position order); nil when it touches none.
public func displayFor(frame: CGRect, displays: [DisplayID: CGRect]) -> DisplayID? {
    var best: (id: DisplayID, area: CGFloat)?
    for id in displaysByPosition(displays) {
        let overlap = frame.intersection(displays[id]!)
        guard !overlap.isNull else {
            continue
        }
        let area = overlap.width * overlap.height
        if area > 0, area > (best?.area ?? 0) {
            best = (id, area)
        }
    }
    return best?.id
}

/// The display next to `display` in `direction` (up = higher Cocoa y). Only
/// displays entirely past the matching edge qualify. Displays that overlap
/// the source on the perpendicular axis win over diagonal ones; then the
/// nearest edge, then the nearest centre, then position order.
public func displayNeighbour(
    of display: DisplayID, direction: FocusDirection, frames: [DisplayID: CGRect]
) -> DisplayID? {
    guard let source = frames[display] else {
        return nil
    }
    let tolerance: CGFloat = 1
    struct Rank: Comparable {
        var detached: Int
        var edge: CGFloat
        var centre: CGFloat
        var position: Int

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.detached, lhs.edge, lhs.centre, lhs.position)
                < (rhs.detached, rhs.edge, rhs.centre, rhs.position)
        }
    }
    var best: (id: DisplayID, rank: Rank)?
    for (position, id) in displaysByPosition(frames).enumerated() where id != display {
        let other = frames[id]!
        let edge: CGFloat
        let overlap: CGFloat
        switch direction {
        case .right:
            edge = other.minX - source.maxX
            overlap = min(source.maxY, other.maxY) - max(source.minY, other.minY)
        case .left:
            edge = source.minX - other.maxX
            overlap = min(source.maxY, other.maxY) - max(source.minY, other.minY)
        case .up:
            edge = other.minY - source.maxY
            overlap = min(source.maxX, other.maxX) - max(source.minX, other.minX)
        case .down:
            edge = source.minY - other.maxY
            overlap = min(source.maxX, other.maxX) - max(source.minX, other.minX)
        }
        guard edge >= -tolerance else {
            continue
        }
        let rank = Rank(
            detached: overlap > 0 ? 0 : 1,
            edge: max(edge, 0),
            centre: hypot(other.midX - source.midX, other.midY - source.midY),
            position: position
        )
        if best.map({ rank < $0.rank }) ?? true {
            best = (id, rank)
        }
    }
    return best?.id
}
