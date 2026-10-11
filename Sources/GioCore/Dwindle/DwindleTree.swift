import CoreGraphics
import Foundation

/// DW-01: how a workspace lays its windows out. Chosen per workspace
/// (`[[workspace]] layout`, `[layout] default-layout`) and switched live
/// (`toggle-workspace-layout`, `set-workspace-layout-*`, `gio layout ...`).
public enum WorkspaceLayoutKind: String, CaseIterable, Equatable, Sendable {
    /// Niri's scrollable strip of columns; the display is a viewport over it.
    case scrolling
    /// Hyprland's dwindle: a binary split tree that fills the display, so
    /// every window is on screen (no scrolling, no parking).
    case dwindle

    /// The other kind (`toggle-workspace-layout`).
    public var toggled: WorkspaceLayoutKind {
        self == .scrolling ? .dwindle : .scrolling
    }
}

/// DW-01: how a split divides its rectangle.
public enum DwindleOrientation: String, Equatable, Sendable {
    /// Side by side: the first child on the left, the second on the right.
    case horizontal
    /// Stacked: the first child on top, the second below (Cocoa: the first
    /// child takes the upper, larger-y part).
    case vertical

    public var flipped: DwindleOrientation {
        self == .horizontal ? .vertical : .horizontal
    }
}

/// Split ratios (Hyprland / OmniWM): the first child's share times two, so
/// 1.0 is half and half, 0.1 gives the first child 5%, 1.9 gives it 95%.
public let dwindleRatioRange: ClosedRange<CGFloat> = 0.1...1.9

/// A ratio clamped into `dwindleRatioRange` (a non-finite one is 1).
public func clampedDwindleRatio(_ ratio: CGFloat) -> CGFloat {
    guard ratio.isFinite else {
        return 1
    }
    return min(max(ratio, dwindleRatioRange.lowerBound), dwindleRatioRange.upperBound)
}

/// One step down the tree: into a split's first or second child.
public enum DwindleSide: Equatable, Hashable, Sendable {
    case first
    case second
}

/// The steps from the root to a node.
public typealias DwindlePath = [DwindleSide]

/// DW-01: one split of the dwindle tree. `orientation` nil follows the
/// shape of the split's rectangle (wider than tall, scaled by
/// `split-width-multiplier`: side by side). The first layout that shows a
/// new split pins it to that shape (`pinningOrientations`), so the split
/// keeps it when ratios or neighbours change later (OmniWM, Hyprland's
/// `preserve_split`); a preselection or `dwindle-toggle-split` pins it too.
public struct DwindleSplit: Equatable, Sendable {
    public var orientation: DwindleOrientation?
    public var ratio: CGFloat
    public var first: DwindleNode
    public var second: DwindleNode

    public init(orientation: DwindleOrientation? = nil, ratio: CGFloat = 1, first: DwindleNode, second: DwindleNode) {
        self.orientation = orientation
        self.ratio = clampedDwindleRatio(ratio)
        self.first = first
        self.second = second
    }

    public func child(_ side: DwindleSide) -> DwindleNode {
        side == .first ? first : second
    }
}

/// DW-01: the dwindle tree. A value type: every operation returns a new tree.
public indirect enum DwindleNode: Equatable, Sendable {
    case leaf(WindowID)
    case split(DwindleSplit)

    /// Every window, first subtree first (left to right, top to bottom for
    /// a tree built by splitting).
    public var windows: [WindowID] {
        var result: [WindowID] = []
        collect(into: &result)
        return result
    }

    private func collect(into result: inout [WindowID]) {
        switch self {
        case .leaf(let id):
            result.append(id)
        case .split(let split):
            split.first.collect(into: &result)
            split.second.collect(into: &result)
        }
    }

    /// The path to the leaf holding `id`, nil when it is not in the tree.
    public func path(to id: WindowID) -> DwindlePath? {
        switch self {
        case .leaf(let leaf):
            return leaf == id ? [] : nil
        case .split(let split):
            if let path = split.first.path(to: id) {
                return [.first] + path
            }
            if let path = split.second.path(to: id) {
                return [.second] + path
            }
            return nil
        }
    }

    /// The node at `path`, nil when the path leaves the tree.
    public func node(at path: DwindlePath) -> DwindleNode? {
        guard let step = path.first else {
            return self
        }
        guard case .split(let split) = self else {
            return nil
        }
        return split.child(step).node(at: Array(path.dropFirst()))
    }

    /// The tree with the node at `path` replaced (unchanged for a path that
    /// leaves the tree).
    public func replacing(at path: DwindlePath, with node: DwindleNode) -> DwindleNode {
        guard let step = path.first else {
            return node
        }
        guard case .split(var split) = self else {
            return self
        }
        let rest = Array(path.dropFirst())
        if step == .first {
            split.first = split.first.replacing(at: rest, with: node)
        } else {
            split.second = split.second.replacing(at: rest, with: node)
        }
        return .split(split)
    }

    /// The tree without `id`: its parent split collapses into the sibling.
    /// Nil when `id` was the only window.
    public func removing(_ id: WindowID) -> DwindleNode? {
        switch self {
        case .leaf(let leaf):
            return leaf == id ? nil : self
        case .split(var split):
            guard let first = split.first.removing(id) else {
                return split.second
            }
            guard let second = split.second.removing(id) else {
                return split.first
            }
            split.first = first
            split.second = second
            return .split(split)
        }
    }

    /// The tree with the windows `a` and `b` trading leaves.
    public func swappingLeaves(_ a: WindowID, _ b: WindowID) -> DwindleNode {
        switch self {
        case .leaf(let id):
            return .leaf(id == a ? b : (id == b ? a : id))
        case .split(var split):
            split.first = split.first.swappingLeaves(a, b)
            split.second = split.second.swappingLeaves(a, b)
            return .split(split)
        }
    }

    /// The tree with `transform` applied to every split (children first).
    public func mappingSplits(_ transform: (DwindleSplit) -> DwindleSplit) -> DwindleNode {
        switch self {
        case .leaf:
            return self
        case .split(var split):
            split.first = split.first.mappingSplits(transform)
            split.second = split.second.mappingSplits(transform)
            return .split(transform(split))
        }
    }

    /// The tree with every unpinned split pinned to the orientation it was
    /// laid out with (`orientations`, by path; splits not laid out, inside
    /// a side that showed nothing, stay unpinned).
    public func pinningOrientations(_ orientations: [DwindlePath: DwindleOrientation], at path: DwindlePath = []) -> DwindleNode {
        guard case .split(var split) = self else {
            return self
        }
        if split.orientation == nil {
            split.orientation = orientations[path]
        }
        split.first = split.first.pinningOrientations(orientations, at: path + [.first])
        split.second = split.second.pinningOrientations(orientations, at: path + [.second])
        return .split(split)
    }
}

/// DW-01: a workspace's dwindle state. Membership is not stored here: the
/// workspace's columns stay the one membership list and the tree is a view
/// of them that `Workspace.reconcileDwindle` keeps in sync (a window can
/// never be lost or duplicated by the tree).
public struct DwindleState: Equatable, Sendable {
    public var root: DwindleNode?
    /// The leaf the next new window splits: the workspace's focused window
    /// as of the last reconcile (the focus may already have moved to the
    /// arriving window when it is inserted).
    public var selected: WindowID?
    /// `dwindle-preselect-*`: the side the next new window takes in the
    /// selected leaf (and the split's orientation). Consumed by it.
    public var preselection: FocusDirection?
    /// `maximize-column` in dwindle: this window fills the working area while
    /// it stays the focused window; the others stay in their tiles behind it.
    public var maximized: WindowID?

    public init(
        root: DwindleNode? = nil, selected: WindowID? = nil,
        preselection: FocusDirection? = nil, maximized: WindowID? = nil
    ) {
        self.root = root
        self.selected = selected
        self.preselection = preselection
        self.maximized = maximized
    }

    /// The tree's windows in leaf order.
    public var windows: [WindowID] {
        root?.windows ?? []
    }

    /// Split the selected leaf (else the last one) and put `id` in the new
    /// half: the second (right / bottom) one, or the preselected side. The
    /// split follows the rectangle's shape unless a preselection pins it.
    /// The new window becomes the selected leaf; the preselection is used up.
    public mutating func insert(_ id: WindowID, ratio: CGFloat) {
        guard let root else {
            self.root = .leaf(id)
            selected = id
            preselection = nil
            return
        }
        let target = selected.flatMap { root.path(to: $0) == nil ? nil : $0 } ?? root.windows.last!
        let path = root.path(to: target)!
        var orientation: DwindleOrientation?
        var newFirst = false
        if let preselection {
            orientation = preselection == .left || preselection == .right ? .horizontal : .vertical
            newFirst = preselection == .left || preselection == .up
        }
        let split = DwindleSplit(
            orientation: orientation, ratio: ratio,
            first: newFirst ? .leaf(id) : .leaf(target),
            second: newFirst ? .leaf(target) : .leaf(id)
        )
        self.root = root.replacing(at: path, with: .split(split))
        selected = id
        preselection = nil
    }

    /// Take `id` out of the tree (its parent collapses into the sibling).
    public mutating func remove(_ id: WindowID) {
        root = root?.removing(id)
        if selected == id {
            selected = nil
        }
        if maximized == id {
            maximized = nil
        }
    }
}

/// DW-04: the tree in one line for `gio status` and `gio layout info`:
/// `(a | b)` side by side, `(a / b)` stacked, `(a ~ b)` a split no layout
/// has shaped yet; the ratio follows the sign when it is not 1
/// (`|1.2`). Windows are `pid:elementID`. Empty for an empty tree.
public func dwindleTreeSummary(_ state: DwindleState) -> String {
    func describe(_ node: DwindleNode) -> String {
        switch node {
        case .leaf(let id):
            return "\(id.pid):\(id.elementID)"
        case .split(let split):
            let sign: String
            switch split.orientation {
            case .horizontal?: sign = "|"
            case .vertical?: sign = "/"
            case nil: sign = "~"
            }
            let ratio = abs(split.ratio - 1) < 0.001 ? "" : String(format: "%g", Double(split.ratio))
            return "(\(describe(split.first)) \(sign)\(ratio) \(describe(split.second)))"
        }
    }
    return state.root.map(describe) ?? ""
}
