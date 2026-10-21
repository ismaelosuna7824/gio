import CoreGraphics
import Foundation

/// DW-01 `[dwindle]` tuning, carried by `LayoutConfig` so every place that
/// already builds the scrolling engine's config reaches it.
public struct DwindleSettings: Equatable, Sendable {
    /// `default-split-ratio`: the ratio a new split starts with (0.1...1.9,
    /// 1 = half and half; it is the first, existing window's share times two).
    public var splitRatio: CGFloat
    /// `split-width-multiplier` (Hyprland): a split lays its children side
    /// by side when `width >= height * multiplier`, else stacks them. Above
    /// 1 favours stacking, below 1 favours side by side.
    public var splitWidthMultiplier: CGFloat

    public init(splitRatio: CGFloat = 1, splitWidthMultiplier: CGFloat = 1) {
        self.splitRatio = splitRatio
        self.splitWidthMultiplier = splitWidthMultiplier
    }
}

/// Where one split was laid out and which way it divided.
public struct DwindleSplitPlacement: Equatable, Sendable {
    public var rect: CGRect
    public var orientation: DwindleOrientation
}

/// DW-01: one dwindle layout. `frames` holds every tiled window; `splits`
/// every split by path (rect and the orientation it was laid out with),
/// which the dwindle actions read to resize or flip the right split.
public struct DwindleLayout: Equatable, Sendable {
    public var frames: [WindowID: CGRect]
    public var splits: [DwindlePath: DwindleSplitPlacement]

    /// The orientation every laid-out split used (`pinningOrientations`).
    public var orientations: [DwindlePath: DwindleOrientation] {
        splits.mapValues(\.orientation)
    }
}

/// DW-01: Hyprland-style dwindle geometry. The usable area (the viewport
/// inset by `padding`) is divided recursively: each split gives its first
/// child `ratio / 2` of the extent left after one `gap`, the second the
/// rest. A split without a pinned orientation lays its children side by
/// side when its rectangle is at least `splitWidthMultiplier` times wider
/// than tall, else stacks them (first on top). A leaf whose window is not
/// tiled (floating, minimized, a fullscreen window covering the display)
/// takes no space: its sibling gets the whole split. Split boundaries are
/// rounded to whole points; every frame is finite and at least 1x1 (an
/// AX requirement). Pure: same inputs, same frames.
public struct DwindleLayoutEngine: Sendable {
    public let config: LayoutConfig
    /// BUG-3: learned minimum sizes (`MinimumSizeBook`, per app across
    /// launches). A split gives each side at least what its windows need
    /// along the split's axis when both fit; when they cannot, the space is
    /// shared in proportion to the two needs (something has to overlap).
    public let minimumSizes: [WindowID: CGSize]

    public init(config: LayoutConfig = LayoutConfig(), minimumSizes: [WindowID: CGSize] = [:]) {
        self.config = config
        self.minimumSizes = minimumSizes
    }

    public func layout(
        _ state: DwindleState, viewport: CGRect, modes: [WindowID: WindowMode] = [:]
    ) throws -> DwindleLayout {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.minX.isFinite, viewport.minY.isFinite,
              viewport.width > 0, viewport.height > 0
        else {
            throw LayoutError.invalidViewport
        }
        let multiplier = config.dwindle.splitWidthMultiplier
        guard config.padding.isFinite, config.gap.isFinite, config.padding >= 0, config.gap >= 0,
              multiplier.isFinite, multiplier > 0
        else {
            throw LayoutError.invalidConfiguration
        }
        let area = viewport.insetBy(dx: config.padding, dy: config.padding)
        guard !area.isNull, area.width > 0, area.height > 0 else {
            throw LayoutError.invalidViewport
        }
        var result = DwindleLayout(frames: [:], splits: [:])
        if let root = state.root {
            place(root, in: area, nominal: area, path: [], tiled: { modes[$0, default: .tiled] == .tiled }, into: &result)
        }
        return result
    }

    /// `nominal` is where the split would sit without minimums: an unpinned
    /// split takes its shape from it, so a side a minimum widened keeps the
    /// orientation its needs were measured with (`requirement`).
    private func place(
        _ node: DwindleNode, in rect: CGRect, nominal: CGRect, path: DwindlePath,
        tiled: (WindowID) -> Bool, into result: inout DwindleLayout
    ) {
        switch node {
        case .leaf(let id):
            if tiled(id) {
                result.frames[id] = CGRect(
                    x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: max(rect.height, 1)
                )
            }
        case .split(let split):
            let orientation = split.orientation ?? shape(of: nominal)
            result.splits[path] = DwindleSplitPlacement(rect: rect, orientation: orientation)
            let firstShown = split.first.windows.contains(where: tiled)
            let secondShown = split.second.windows.contains(where: tiled)
            guard firstShown, secondShown else {
                // One side shows nothing: the other side gets the whole split.
                if firstShown {
                    place(split.first, in: rect, nominal: nominal, path: path + [.first], tiled: tiled, into: &result)
                } else if secondShown {
                    place(split.second, in: rect, nominal: nominal, path: path + [.second], tiled: tiled, into: &result)
                }
                return
            }
            let fraction = minimumAwareFraction(split, in: rect, nominal: nominal, orientation: orientation, tiled: tiled)
            let (first, second) = divide(rect, orientation: orientation, fraction: fraction)
            let nominalHalves = divide(nominal, orientation: orientation, fraction: clampedDwindleRatio(split.ratio) / 2)
            place(split.first, in: first, nominal: nominalHalves.first, path: path + [.first], tiled: tiled, into: &result)
            place(split.second, in: second, nominal: nominalHalves.second, path: path + [.second], tiled: tiled, into: &result)
        }
    }

    /// Side by side when the rectangle is wide enough (Hyprland's
    /// `split_width_multiplier` rule), stacked otherwise.
    func shape(of rect: CGRect) -> DwindleOrientation {
        rect.width >= rect.height * config.dwindle.splitWidthMultiplier ? .horizontal : .vertical
    }

    /// The first child's share of the split (0...1): `ratio / 2`, moved just
    /// enough to give each side its minimum along the axis when both fit,
    /// else the two minimums' proportion.
    private func minimumAwareFraction(
        _ split: DwindleSplit, in rect: CGRect, nominal: CGRect, orientation: DwindleOrientation,
        tiled: (WindowID) -> Bool
    ) -> CGFloat {
        let fraction = clampedDwindleRatio(split.ratio) / 2
        guard !minimumSizes.isEmpty else {
            return fraction
        }
        let (first, second) = divide(nominal, orientation: orientation, fraction: fraction)
        let firstNeed = requirement(split.first, in: first, tiled: tiled)
        let secondNeed = requirement(split.second, in: second, tiled: tiled)
        let horizontal = orientation == .horizontal
        let needA = horizontal ? firstNeed.width : firstNeed.height
        let needB = horizontal ? secondNeed.width : secondNeed.height
        let available = max((horizontal ? rect.width : rect.height) - config.gap, 0)
        guard available > 0, needA > 0 || needB > 0 else {
            return fraction
        }
        guard needA + needB <= available else {
            return needA / (needA + needB)
        }
        let extent = min(max(available * fraction, needA), available - needB)
        return extent / available
    }

    /// What a subtree needs: side by side, the widths add up (plus the gap)
    /// and the tallest counts; stacked, the other way round. Orientations
    /// are the ones `place` would use in `rect`.
    private func requirement(_ node: DwindleNode, in rect: CGRect, tiled: (WindowID) -> Bool) -> CGSize {
        switch node {
        case .leaf(let id):
            return tiled(id) ? (minimumSizes[id] ?? .zero) : .zero
        case .split(let split):
            let firstShown = split.first.windows.contains(where: tiled)
            let secondShown = split.second.windows.contains(where: tiled)
            guard firstShown, secondShown else {
                return firstShown ? requirement(split.first, in: rect, tiled: tiled)
                    : secondShown ? requirement(split.second, in: rect, tiled: tiled) : .zero
            }
            let orientation = split.orientation ?? shape(of: rect)
            let (first, second) = divide(rect, orientation: orientation, fraction: clampedDwindleRatio(split.ratio) / 2)
            let a = requirement(split.first, in: first, tiled: tiled)
            let b = requirement(split.second, in: second, tiled: tiled)
            switch orientation {
            case .horizontal:
                return CGSize(width: a.width + b.width + (a.width > 0 && b.width > 0 ? config.gap : 0),
                              height: max(a.height, b.height))
            case .vertical:
                return CGSize(width: max(a.width, b.width),
                              height: a.height + b.height + (a.height > 0 && b.height > 0 ? config.gap : 0))
            }
        }
    }

    /// The two children's rectangles: the first takes `ratio / 2` of what
    /// is left after the gap (left, or top in Cocoa's y-up space).
    func divide(
        _ rect: CGRect, orientation: DwindleOrientation, ratio: CGFloat
    ) -> (first: CGRect, second: CGRect) {
        divide(rect, orientation: orientation, fraction: clampedDwindleRatio(ratio) / 2)
    }

    private func divide(
        _ rect: CGRect, orientation: DwindleOrientation, fraction: CGFloat
    ) -> (first: CGRect, second: CGRect) {
        let gap = config.gap
        switch orientation {
        case .horizontal:
            let available = max(rect.width - gap, 0)
            let firstWidth = (available * fraction).rounded()
            return (
                CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                CGRect(x: rect.minX + firstWidth + gap, y: rect.minY, width: available - firstWidth, height: rect.height)
            )
        case .vertical:
            let available = max(rect.height - gap, 0)
            let firstHeight = (available * fraction).rounded()
            return (
                CGRect(x: rect.minX, y: rect.maxY - firstHeight, width: rect.width, height: firstHeight),
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: available - firstHeight)
            )
        }
    }
}
