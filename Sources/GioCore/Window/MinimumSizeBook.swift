import CoreGraphics
import Foundation

/// FI-02: what a failed write says about the window's unpublished minimum
/// size. Accessibility exposes no minimum-size attribute, so the only
/// evidence is a write that landed larger than requested.
///
/// A dimension counts as a clamp when the window ended up larger than
/// requested by more than `tolerance` AND that growth is anchored to one
/// edge: the origin edge (left/bottom in Cocoa) or the far edge (right/top)
/// stayed where it was asked to be. If both edges moved the window was
/// pushed (position clamping), which says nothing about its minimum size.
/// A window that landed smaller, or the same size somewhere else, is never
/// learned from; neither is one that grew in one dimension while the other
/// landed smaller: a screen constrained it (MM-11: a window sent to a
/// taller display kept its top at the other display's visible top and came
/// back wider). Returns 0 for a dimension without evidence, nil when there
/// is none at all. Works in either vertical orientation.
public func learnedMinimum(requested: CGRect, actual: CGRect, tolerance: CGFloat = 1) -> CGSize? {
    func clamped(
        _ requestedMin: CGFloat, _ requestedMax: CGFloat, _ actualMin: CGFloat, _ actualMax: CGFloat
    ) -> CGFloat {
        let grew = (actualMax - actualMin) - (requestedMax - requestedMin) > tolerance
        let anchored = abs(actualMin - requestedMin) <= tolerance || abs(actualMax - requestedMax) <= tolerance
        return grew && anchored ? actualMax - actualMin : 0
    }
    guard requested.isFinite, actual.isFinite,
          requested.width - actual.width <= tolerance, requested.height - actual.height <= tolerance
    else {
        return nil
    }
    let width = clamped(requested.minX, requested.maxX, actual.minX, actual.maxX)
    let height = clamped(requested.minY, requested.maxY, actual.minY, actual.maxY)
    return width > 0 || height > 0 ? CGSize(width: width, height: height) : nil
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}

/// Learned per-window minimum sizes for the session. Values only grow (the
/// maximum of everything learned); a window that is forgotten (purged or
/// re-registered) starts over. Pure value type; the host owns one.
public struct MinimumSizeBook: Equatable, Sendable {
    public private(set) var sizes: [WindowID: CGSize] = [:]
    /// FI-11: windows a display-change pass placed last.
    private var displayPlaced: Set<WindowID> = []

    public init() {}

    public func size(of id: WindowID) -> CGSize? {
        sizes[id]
    }

    /// Learn from one landing. Returns the merged minimum when it grew,
    /// nil when there was nothing new.
    @discardableResult
    public mutating func learn(
        _ id: WindowID, requested: CGRect, actual: CGRect, tolerance: CGFloat = 1
    ) -> CGSize? {
        guard let learned = learnedMinimum(requested: requested, actual: actual, tolerance: tolerance) else {
            return nil
        }
        let known = sizes[id] ?? .zero
        let merged = CGSize(
            width: max(known.width, learned.width), height: max(known.height, learned.height)
        )
        guard merged.width > known.width + tolerance || merged.height > known.height + tolerance else {
            return nil
        }
        sizes[id] = merged
        return merged
    }

    /// Learn from every landing mismatch of a reconcile pass. Returns the
    /// windows whose minimum grew, so the host can log and relayout.
    /// A pass placed for a display change (`placement` is
    /// `.instant(.displays)`) teaches nothing: macOS and the apps re-place
    /// windows across a reconfiguration themselves, so a size that did not
    /// land then is no evidence of a minimum (live: Slack and OrbStack kept
    /// their 1068 from the other display and were learned 1068 wide for the
    /// session). A real minimum fails again in the next pass and is learned
    /// there.
    public mutating func learn(from report: ReconcileReport, placement: InstantPlacementDecision) -> [WindowID: CGSize] {
        guard placement != .instant(.displays) else {
            return [:]
        }
        var changed: [WindowID: CGSize] = [:]
        for id in report.failed.sorted() {
            guard let failure = report.failures[id], failure.kind == ReconcileFailure.frameMismatchKind,
                  let requested = failure.requested, let actual = failure.actual,
                  let merged = learn(id, requested: requested, actual: actual)
            else {
                continue
            }
            changed[id] = merged
        }
        return changed
    }

    /// FI-11: the windows a settled pass placed, so a late clamp of a
    /// display-change pass teaches nothing either (see `learn(from:)`).
    public mutating func notePlaced(_ ids: some Sequence<WindowID>, placement: InstantPlacementDecision) {
        if placement == .instant(.displays) {
            displayPlaced.formUnion(ids)
        } else {
            displayPlaced.subtract(ids)
        }
    }

    /// FI-11: learn from a clamp the app applied after Gio's read-back
    /// (`requested`: Gio's last write; `actual`: the frame read once its
    /// echo window ended). Nil when nothing new was learned, or when a
    /// display-change pass placed the window last.
    public mutating func learnLate(_ id: WindowID, requested: CGRect, actual: CGRect) -> CGSize? {
        guard !displayPlaced.contains(id) else {
            return nil
        }
        return learn(id, requested: requested, actual: actual)
    }

    public mutating func forget(_ id: WindowID) {
        sizes.removeValue(forKey: id)
        displayPlaced.remove(id)
    }
}

/// Heights for a stacked column: `weights` share `available` as before, but
/// no window gets less than its minimum where the column can afford it. Windows
/// below their minimum are pinned to it and the rest re-share what is left
/// by weight. When the minimums together exceed `available` the plain
/// proportional split is returned (something has to give).
public func distributeHeights(available: CGFloat, weights: [CGFloat], minimums: [CGFloat]) -> [CGFloat] {
    let count = weights.count
    let totalWeight = weights.reduce(0, +)
    let proportional = weights.map { available * $0 / totalWeight }
    let floors = (0..<count).map { $0 < minimums.count ? max(minimums[$0], 0) : 0 }
    guard floors.contains(where: { $0 > 0 }), floors.reduce(0, +) <= available else {
        return proportional
    }
    var pinned = [Bool](repeating: false, count: count)
    var heights = proportional
    for _ in 0...count {
        let remaining = available - (0..<count).filter { pinned[$0] }.reduce(0) { $0 + floors[$1] }
        let freeWeight = (0..<count).filter { !pinned[$0] }.reduce(0) { $0 + weights[$1] }
        var changed = false
        for index in 0..<count where !pinned[index] {
            heights[index] = freeWeight > 0 ? remaining * weights[index] / freeWeight : 0
            if heights[index] < floors[index] {
                pinned[index] = true
                changed = true
            }
        }
        if !changed {
            break
        }
    }
    for index in 0..<count where pinned[index] {
        heights[index] = floors[index]
    }
    return heights
}
