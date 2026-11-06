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
/// back wider). FX-05: a request below `minimumEvidenceExtent` says nothing
/// on its axis (a 1 pt dwindle tile came back at the window's column
/// width). FI-17: neither does an axis that kept its extent from `before`,
/// the frame read just before the write (the app did not resize at all;
/// live: Zen back from a fullscreen Space stayed at its old 1496 pt). Nil
/// `before` is unknown and changes nothing. Returns 0 for a dimension
/// without evidence, nil when there is none at all. Works in either
/// vertical orientation.
public func learnedMinimum(
    requested: CGRect, actual: CGRect, before: CGRect? = nil, tolerance: CGFloat = 1
) -> CGSize? {
    func clamped(
        _ requestedMin: CGFloat, _ requestedMax: CGFloat, _ actualMin: CGFloat, _ actualMax: CGFloat,
        _ beforeExtent: CGFloat?
    ) -> CGFloat {
        guard requestedMax - requestedMin >= minimumEvidenceExtent else {
            return 0
        }
        if let beforeExtent, abs((actualMax - actualMin) - beforeExtent) <= tolerance {
            return 0
        }
        let grew = (actualMax - actualMin) - (requestedMax - requestedMin) > max(tolerance, minimumClampSlack)
        let anchored = abs(actualMin - requestedMin) <= tolerance || abs(actualMax - requestedMax) <= tolerance
        return grew && anchored ? actualMax - actualMin : 0
    }
    guard requested.isFinite, actual.isFinite,
          requested.width - actual.width <= tolerance, requested.height - actual.height <= tolerance
    else {
        return nil
    }
    let before = before.flatMap { $0.isFinite ? $0 : nil }
    let width = clamped(requested.minX, requested.maxX, actual.minX, actual.maxX, before?.width)
    let height = clamped(requested.minY, requested.maxY, actual.minY, actual.maxY, before?.height)
    return width > 0 || height > 0 ? CGSize(width: width, height: height) : nil
}

/// FX-05: the smallest request a clamp is learned from.
public let minimumEvidenceExtent: CGFloat = 100

/// NC-15: growth up to this much is an app rounding the size to its grid
/// (Terminal's character cells: half a cell either way), never a minimum.
/// Learned, it kept a stretched column from shrinking back.
public let minimumClampSlack: CGFloat = 16

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}

/// FI-17: the strip a frame is tiled in, among `strips` (each display's
/// viewport without the layout padding): the one it overlaps most, else the
/// nearest. Nil when no strip is known.
func tilingStrip(holding frame: CGRect, in strips: [CGRect]) -> CGRect? {
    func overlap(_ strip: CGRect) -> CGFloat {
        let common = strip.intersection(frame)
        return common.isNull ? 0 : common.width * common.height
    }
    func distance(_ strip: CGRect) -> CGFloat {
        hypot(strip.midX - frame.midX, strip.midY - frame.midY)
    }
    return strips.max { lhs, rhs in
        let (left, right) = (overlap(lhs), overlap(rhs))
        return left != right ? left < right : distance(lhs) > distance(rhs)
    }
}

/// FI-17: a clamp the book did not learn, and why: `settling` (the window
/// had just registered, or the managed Space had just come back),
/// `unchanged` (the window kept the size it had before the write, seen for
/// the first time), `full-width`, `full-height` or `full-size` (as large as
/// the strip the window is tiled in: the window not resized yet, never a
/// minimum).
public struct IgnoredMinimum: Equatable, Sendable {
    public var size: CGSize
    public var reason: String

    public init(size: CGSize, reason: String) {
        self.size = size
        self.reason = reason
    }
}

/// What a pass (or a late re-check) taught the book: the windows whose
/// minimum grew, the clamps it ignored, and when another write of those
/// windows would be evidence (`recheckAt`: a settle's end, or now for a
/// size kept for the first time); the host reflows then.
public struct MinimumLearning: Equatable, Sendable {
    public var learned: [WindowID: CGSize]
    public var ignored: [WindowID: IgnoredMinimum]
    public var recheckAt: TimeInterval?

    public init(
        learned: [WindowID: CGSize] = [:], ignored: [WindowID: IgnoredMinimum] = [:], recheckAt: TimeInterval? = nil
    ) {
        self.learned = learned
        self.ignored = ignored
        self.recheckAt = recheckAt
    }
}

/// Learned per-window minimum sizes for the session. Values only grow (the
/// maximum of everything learned); a window that is forgotten (purged or
/// re-registered) starts over. Pure value type; the host owns one.
public struct MinimumSizeBook: Equatable, Sendable {
    /// FI-17: how long a window that just registered, or every window after
    /// the managed Space came back, may still be animating to an old size.
    public static let settleDuration: TimeInterval = 1.5

    public private(set) var sizes: [WindowID: CGSize] = [:]
    /// FI-11: windows a display-change pass placed last.
    private var displayPlaced: Set<WindowID> = []
    /// FI-17: settle ends of windows that registered lately, and of all
    /// windows since the managed Space came back.
    private var settlingUntil: [WindowID: TimeInterval] = [:]
    private var spaceSettlingUntil: TimeInterval = -.infinity
    /// FI-17: the clamp a window's last failed write showed but did not
    /// teach (settling, or a size it kept); the same size on the next write
    /// is the app refusing twice, which is evidence. A write that landed
    /// clears it.
    private var pending: [WindowID: CGSize] = [:]

    public init() {}

    public func size(of id: WindowID) -> CGSize? {
        sizes[id]
    }

    /// FI-17: `id` registered at `now`; its clamps teach nothing until it settled.
    public mutating func noteRegistered(_ id: WindowID, at now: TimeInterval) {
        settlingUntil[id] = now + Self.settleDuration
    }

    /// FI-17: the managed Space came back at `now` (windows return from a
    /// fullscreen Space still at their old size).
    public mutating func noteSpaceReturned(at now: TimeInterval) {
        spaceSettlingUntil = now + Self.settleDuration
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
        return merge(id, learned, tolerance: tolerance)
    }

    private mutating func merge(_ id: WindowID, _ learned: CGSize, tolerance: CGFloat) -> CGSize? {
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

    /// Learn from every landing mismatch of a reconcile pass, with the
    /// FI-17 rules (`judge`). `strips`: each display's viewport without the
    /// layout padding. The result's `learned` are the windows whose minimum
    /// grew, so the host can log and relayout.
    /// A pass placed for a display change (`placement` is
    /// `.instant(.displays)`) teaches nothing: macOS and the apps re-place
    /// windows across a reconfiguration themselves, so a size that did not
    /// land then is no evidence of a minimum (live: Slack and OrbStack kept
    /// their 1068 from the other display and were learned 1068 wide for the
    /// session). A real minimum fails again in the next pass and is learned
    /// there.
    public mutating func learn(
        from report: ReconcileReport, placement: InstantPlacementDecision, now: TimeInterval, strips: [CGRect]
    ) -> MinimumLearning {
        var result = MinimumLearning()
        for id in report.applied + report.alreadyCorrect {
            pending.removeValue(forKey: id)
        }
        guard placement != .instant(.displays) else {
            return result
        }
        for id in report.failed.sorted() {
            guard let failure = report.failures[id], failure.kind == ReconcileFailure.frameMismatchKind,
                  let requested = failure.requested, let actual = failure.actual
            else {
                continue
            }
            judge(id, requested: requested, actual: actual, before: failure.before, now: now, strips: strips, into: &result)
        }
        return result
    }

    /// FI-17: a clamp is not learned while the window settles (it may still
    /// be animating to an old size); an axis the window kept from before
    /// the write counts only when the previous write showed the same clamp
    /// (the app refused twice; a lagging app applies the size meanwhile);
    /// an axis as large as the strip the window is tiled in never counts.
    /// The other axis still does. A clamp held back is `pending` for the
    /// next write: after a settle, or at once for a first kept size, the
    /// result asks for another look (`recheckAt`).
    private mutating func judge(
        _ id: WindowID, requested: CGRect, actual: CGRect, before: CGRect?, now: TimeInterval, strips: [CGRect],
        tolerance: CGFloat = 1, into result: inout MinimumLearning
    ) {
        guard let clamp = learnedMinimum(requested: requested, actual: actual, tolerance: tolerance) else {
            return
        }
        let seen = pending.removeValue(forKey: id)
        if let end = settleEnd(of: id, now: now) {
            pending[id] = clamp
            result.ignored[id] = IgnoredMinimum(size: clamp, reason: "settling")
            result.recheckAt = max(result.recheckAt ?? end, end)
            return
        }
        let changed = learnedMinimum(requested: requested, actual: actual, before: before, tolerance: tolerance) ?? .zero
        func counted(_ value: CGFloat, _ changed: CGFloat, _ seen: CGFloat?) -> CGFloat {
            changed > 0 || seen.map({ $0 > 0 && abs($0 - value) <= tolerance }) == true ? value : 0
        }
        var size = CGSize(
            width: counted(clamp.width, changed.width, seen?.width),
            height: counted(clamp.height, changed.height, seen?.height)
        )
        if size != clamp {
            pending[id] = clamp
            result.ignored[id] = IgnoredMinimum(size: clamp, reason: "unchanged")
            if seen == nil {
                result.recheckAt = max(result.recheckAt ?? now, now)
            }
        }
        if let strip = tilingStrip(holding: requested, in: strips) {
            let wide = size.width > 0 && size.width >= strip.width - tolerance
            let tall = size.height > 0 && size.height >= strip.height - tolerance
            if wide || tall {
                result.ignored[id] = IgnoredMinimum(
                    size: clamp, reason: wide && tall ? "full-size" : wide ? "full-width" : "full-height"
                )
                size = CGSize(width: wide ? 0 : size.width, height: tall ? 0 : size.height)
            }
        }
        guard size.width > 0 || size.height > 0, let merged = merge(id, size, tolerance: tolerance) else {
            return
        }
        result.learned[id] = merged
    }

    /// FI-17: when `id`'s settle ends, nil once it has (an expired own
    /// entry is dropped).
    private mutating func settleEnd(of id: WindowID, now: TimeInterval) -> TimeInterval? {
        let own = settlingUntil[id]
        if let own, own <= now {
            settlingUntil.removeValue(forKey: id)
        }
        let end = max(own ?? -.infinity, spaceSettlingUntil)
        return now < end ? end : nil
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
    /// echo window ended), with the FI-17 rules. Nothing is learned when a
    /// display-change pass placed the window last.
    public mutating func learnLate(
        _ id: WindowID, requested: CGRect, actual: CGRect, now: TimeInterval, strips: [CGRect]
    ) -> MinimumLearning {
        var result = MinimumLearning()
        guard !displayPlaced.contains(id) else {
            return result
        }
        judge(id, requested: requested, actual: actual, before: nil, now: now, strips: strips, into: &result)
        return result
    }

    /// BUG-3: `actual` is a clamp of `requested` that the window's known
    /// minimum already accounts for (each clamped dimension within
    /// `tolerance` of it): the app sits at its minimum because the layout
    /// could not give it more (a crowded dwindle tree), not taking its frame
    /// back. The caller neither counts it as a snap-back nor relayouts.
    public func explains(_ id: WindowID, requested: CGRect, actual: CGRect, tolerance: CGFloat = 1) -> Bool {
        guard let known = sizes[id],
              let clamp = learnedMinimum(requested: requested, actual: actual, tolerance: tolerance)
        else {
            return false
        }
        return clamp.width <= known.width + tolerance && clamp.height <= known.height + tolerance
    }

    public mutating func forget(_ id: WindowID) {
        sizes.removeValue(forKey: id)
        displayPlaced.remove(id)
        settlingUntil.removeValue(forKey: id)
        pending.removeValue(forKey: id)
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
