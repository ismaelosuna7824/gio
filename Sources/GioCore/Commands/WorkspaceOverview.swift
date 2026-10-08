import CoreGraphics
import Foundation

/// WO-01: the workspace overview (niri `toggle-overview`). The focused
/// display's whole stack as strips, one per workspace in stack order, built
/// on the session queue from the same layout math as the DD-02 miniature.
/// Selection is pure so the panel only maps keys to steps.
public struct WorkspaceOverviewFacts: Equatable, Sendable {
    public let displayID: UInt32
    /// 1-based index of the workspace the display shows.
    public let activeWorkspace: Int
    /// Stack order, `workspace` 1-based; a workspace whose layout failed is
    /// left out, so look rows up with `strip(_:)`, not by position.
    public let strips: [WorkspaceStripFact]

    public init(displayID: UInt32, activeWorkspace: Int, strips: [WorkspaceStripFact]) {
        self.displayID = displayID
        self.activeWorkspace = activeWorkspace
        self.strips = strips
    }

    public func strip(_ workspace: Int) -> WorkspaceStripFact? {
        strips.first { $0.workspace == workspace }
    }
}

/// What Enter picks: a window (`windowID`), or the bare workspace when the
/// row has no windows.
public struct OverviewSelection: Equatable, Sendable {
    public var workspace: Int
    public var windowID: String?

    public init(workspace: Int, windowID: String?) {
        self.workspace = workspace
        self.windowID = windowID
    }
}

public enum OverviewStep: Equatable, Sendable {
    case left, right, up, down
}

/// Window ids of a strip in reading order: columns left to right, each
/// column top to bottom.
public func overviewWindowOrder(_ strip: WorkspaceStripFact) -> [String] {
    strip.columns.flatMap { $0.windows.map(\.id) }
}

extension WorkspaceOverviewFacts {
    /// The display's workspace on its focused window (first window, else none).
    public var initialSelection: OverviewSelection {
        selection(onWorkspace: activeWorkspace) ?? OverviewSelection(workspace: activeWorkspace, windowID: nil)
    }

    /// A whole row: its focused window, else its first, else the bare
    /// workspace. Nil past the stack.
    public func selection(onWorkspace workspace: Int) -> OverviewSelection? {
        guard let strip = strip(workspace) else {
            return nil
        }
        let order = overviewWindowOrder(strip)
        let focused = strip.focusedWindowID.flatMap { order.contains($0) ? $0 : nil }
        return OverviewSelection(workspace: workspace, windowID: focused ?? order.first)
    }

    /// Left/right walk the row's reading order; up/down move one workspace
    /// and land on the window nearest the same on-screen place. Every edge
    /// stops (no wrap).
    public func selection(_ current: OverviewSelection, stepping step: OverviewStep) -> OverviewSelection {
        switch step {
        case .left, .right:
            guard let strip = strip(current.workspace), let id = current.windowID else {
                return current
            }
            let order = overviewWindowOrder(strip)
            guard let index = order.firstIndex(of: id) else {
                return current
            }
            let next = index + (step == .left ? -1 : 1)
            guard order.indices.contains(next) else {
                return current
            }
            return OverviewSelection(workspace: current.workspace, windowID: order[next])
        case .up, .down:
            let target = current.workspace + (step == .up ? -1 : 1)
            guard let row = selection(onWorkspace: target), let targetStrip = strip(target) else {
                return current
            }
            guard let id = current.windowID, let strip = strip(current.workspace),
                  let anchor = onScreenCenter(of: id, in: strip),
                  let nearest = nearestWindow(to: anchor, in: targetStrip)
            else {
                return row
            }
            return OverviewSelection(workspace: target, windowID: nearest)
        }
    }

    /// Centre of a window in viewport (on-screen) coordinates.
    private func onScreenCenter(of id: String, in strip: WorkspaceStripFact) -> CGPoint? {
        for column in strip.columns {
            if let window = column.windows.first(where: { $0.id == id }) {
                return CGPoint(
                    x: column.x - strip.viewportOffset + column.width / 2,
                    y: window.top + window.height / 2
                )
            }
        }
        return nil
    }

    /// The column whose centre is horizontally nearest, then its window
    /// nearest vertically. First wins ties.
    private func nearestWindow(to point: CGPoint, in strip: WorkspaceStripFact) -> String? {
        let column = strip.columns.filter { !$0.windows.isEmpty }.min { lhs, rhs in
            abs(lhs.x - strip.viewportOffset + lhs.width / 2 - point.x)
                < abs(rhs.x - strip.viewportOffset + rhs.width / 2 - point.x)
        }
        return column?.windows.min { lhs, rhs in
            abs(lhs.top + lhs.height / 2 - point.y) < abs(rhs.top + rhs.height / 2 - point.y)
        }?.id
    }
}
