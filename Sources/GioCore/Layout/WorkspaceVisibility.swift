import CoreGraphics
import Foundation

/// NC-06 / MM-03: where a window of an inactive workspace hangs, size kept,
/// never on another display. The first free place wins:
/// 1. below the display (only the parking sliver stays inside), so it never
///    sits on the left/right band that side parking uses: the bottom-right
///    corner, then the bottom-left one;
/// 2. a display below overlaps both (vertically stacked displays): off the
///    right side, then the left side, level with the display's top (its
///    bottom when the window is taller), like side parking;
/// 3. every side overlaps a display: the bottom-right corner of the union
///    of all displays: at most its 1 pt sliver touches the display in that
///    corner (when no display has that corner, macOS may clamp it).
public func hiddenTarget(
    for frame: CGRect, display: CGRect, otherDisplays: [CGRect]
) -> ParkedTarget {
    let below = display.minY - frame.height + parkingSliver
    let side = max(display.minY, display.maxY - frame.height)
    let rightX = display.maxX - parkingSliver
    let leftX = display.minX - frame.width + parkingSliver
    let candidates: [(CGPoint, ParkEdge)] = [
        (CGPoint(x: rightX, y: below), .corner),
        (CGPoint(x: leftX, y: below), .corner),
        (CGPoint(x: rightX, y: side), .right),
        (CGPoint(x: leftX, y: side), .left),
    ]
    for (origin, edge) in candidates {
        let rect = CGRect(origin: origin, size: frame.size)
        if !otherDisplays.contains(where: { $0.intersects(rect) }) {
            return ParkedTarget(frame: rect, edge: edge, display: display)
        }
    }
    let union = otherDisplays.reduce(display) { $0.union($1) }
    let corner = CGRect(
        x: union.maxX - parkingSliver, y: union.minY - frame.height + parkingSliver,
        width: frame.width, height: frame.height
    )
    return ParkedTarget(frame: corner, edge: .corner, display: display)
}

/// Hidden positions for every window of an inactive workspace.
public func planHiddenWindows(
    frames: [WindowID: CGRect], display: CGRect, otherDisplays: [CGRect]
) -> [WindowID: ParkedTarget] {
    frames.mapValues { hiddenTarget(for: $0, display: display, otherDisplays: otherDisplays) }
}

/// Remembers where windows were before they were hidden. Tiled windows come
/// back through layout, but a floating window's frame is its own: it returns
/// exactly there when its workspace is shown again. MM-03: it also holds the
/// frame a floating window must move to when its workspace changed display.
public struct HiddenWindowBook: Equatable, Sendable {
    private var originals: [WindowID: CGRect] = [:]

    public init() {}

    public func isHidden(_ id: WindowID) -> Bool {
        originals[id] != nil
    }

    /// Record the frame the window had before hiding. Only the first call
    /// counts: later ones would see the hidden frame.
    public mutating func hide(_ id: WindowID, from frame: CGRect) {
        if originals[id] == nil {
            originals[id] = frame
        }
    }

    /// MM-03: replace (or start) the remembered frame: the window's workspace
    /// moved to another display, so it returns, or goes now, over there.
    public mutating func move(_ id: WindowID, to frame: CGRect) {
        originals[id] = frame
    }

    /// The remembered frames of those that are hidden, without forgetting.
    public func frames(of ids: some Sequence<WindowID>) -> [WindowID: CGRect] {
        var found: [WindowID: CGRect] = [:]
        for id in ids {
            if let frame = originals[id] {
                found[id] = frame
            }
        }
        return found
    }

    /// Forget and return the remembered frames of those that were hidden.
    public mutating func reveal(_ ids: some Sequence<WindowID>) -> [WindowID: CGRect] {
        var restored: [WindowID: CGRect] = [:]
        for id in ids {
            if let frame = originals.removeValue(forKey: id) {
                restored[id] = frame
            }
        }
        return restored
    }
}

/// MM-03: where a floating window lands when its workspace takes it to
/// another display (niri moves floating windows between monitors): its size
/// kept, its offset from the visible-frame origin kept, then clamped inside
/// the target's visible frame. A window larger than the target keeps its
/// size and is pinned to the target's top-left, so its title bar stays
/// reachable.
public func relocatedFloatingFrame(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
    let x = frame.minX - source.minX + target.minX
    let y = frame.minY - source.minY + target.minY
    return CGRect(
        x: max(target.minX, min(x, target.maxX - frame.width)),
        y: min(target.maxY - frame.height, max(y, target.minY)),
        width: frame.width, height: frame.height
    )
}

/// MM-03: the floating windows whose workspace is on another display than
/// the last pass saw (`previous` to `current`, by display ID) and where each
/// goes. A window seen for the first time, one whose display is unchanged,
/// one whose old display is gone (macOS moved it already), one without a
/// known frame and one already centred on its new display stay where they
/// are. `frames`: where each window is, or returns to when it is hidden.
public func planFloatingRelocations(
    frames: [WindowID: CGRect],
    previous: [WindowID: DisplayID],
    current: [WindowID: DisplayID],
    visibleFrames: [DisplayID: CGRect]
) -> [WindowID: CGRect] {
    var moves: [WindowID: CGRect] = [:]
    for (id, display) in current {
        guard let before = previous[id], before != display,
              let source = visibleFrames[before], let target = visibleFrames[display],
              let frame = frames[id], !target.contains(CGPoint(x: frame.midX, y: frame.midY))
        else {
            continue
        }
        moves[id] = relocatedFloatingFrame(frame, from: source, to: target)
    }
    return moves
}

extension WorkspaceManager {
    /// Windows that belong to a workspace no display shows: the ones a
    /// reflow must hide.
    public func windows(outside shown: Set<WorkspaceID>) -> Set<WindowID> {
        var hidden: Set<WindowID> = []
        for workspace in allWorkspaces where !shown.contains(workspace.id) {
            for column in workspace.columns {
                hidden.formUnion(column.windows)
            }
        }
        return hidden
    }
}

extension DisplayManager {
    /// Make sure `workspace` is on some display. Already shown: nothing
    /// changes. Otherwise the display that showed `previous` (the first
    /// display when there is none) switches to it. True when a display was
    /// reassigned.
    @discardableResult
    public mutating func show(_ workspace: WorkspaceID, replacing previous: WorkspaceID?) -> Bool {
        let all = allDisplays()
        guard !all.contains(where: { $0.workspace == workspace }) else {
            return false
        }
        let target = previous.flatMap { previous in all.first { $0.workspace == previous } } ?? all.first
        guard let target else {
            return false
        }
        return assign(target.id, workspace: workspace)
    }
}
