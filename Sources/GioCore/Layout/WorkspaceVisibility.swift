import CoreGraphics
import Foundation

/// NC-06: where a window of an inactive workspace hangs. Always below the
/// display (only the parking sliver stays inside), so it can never sit on the
/// left/right band that side parking uses. The bottom-right corner is
/// preferred; when a neighbouring display would overlap it the bottom-left
/// corner is tried, and bottom-right remains the last resort (the same
/// fallback `planParking` uses). Size is kept.
public func hiddenTarget(
    for frame: CGRect, display: CGRect, otherDisplays: [CGRect]
) -> ParkedTarget {
    let y = display.minY - frame.height + parkingSliver
    let bottomRight = CGRect(
        x: display.maxX - parkingSliver, y: y, width: frame.width, height: frame.height
    )
    let bottomLeft = CGRect(
        x: display.minX - frame.width + parkingSliver, y: y,
        width: frame.width, height: frame.height
    )
    let chosen = [bottomRight, bottomLeft].first { rect in
        !otherDisplays.contains { $0.intersects(rect) }
    } ?? bottomRight
    return ParkedTarget(frame: chosen, edge: .corner, display: display)
}

/// Hidden positions for every window of an inactive workspace.
public func planHiddenWindows(
    frames: [WindowID: CGRect], display: CGRect, otherDisplays: [CGRect]
) -> [WindowID: ParkedTarget] {
    frames.mapValues { hiddenTarget(for: $0, display: display, otherDisplays: otherDisplays) }
}

/// Remembers where windows were before they were hidden. Tiled windows come
/// back through layout, but a floating window's frame is its own: it returns
/// exactly there when its workspace is shown again.
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
