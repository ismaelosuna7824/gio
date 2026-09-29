import CoreGraphics
import Foundation

/// Plan §9 tuning. All values are points. `defaultColumnWidth` applies to
/// columns with non-positive width; nil means half the viewport width.
public struct LayoutConfig: Equatable, Sendable {
    public var padding: CGFloat
    public var gap: CGFloat
    public var defaultColumnWidth: CGFloat?
    public var minimumColumnWidth: CGFloat

    public init(
        padding: CGFloat = 8,
        gap: CGFloat = 8,
        defaultColumnWidth: CGFloat? = nil,
        minimumColumnWidth: CGFloat = 200
    ) {
        self.padding = padding
        self.gap = gap
        self.defaultColumnWidth = defaultColumnWidth
        self.minimumColumnWidth = minimumColumnWidth
    }
}

extension LayoutConfig {
    /// The width a spec takes on a viewport of `viewportWidth`, floored at
    /// `minimumColumnWidth`. The engine and the width actions share this so
    /// what the user sees is what the actions compare against.
    public func resolvedWidth(of spec: ColumnWidthSpec, viewportWidth: CGFloat) -> CGFloat {
        let raw: CGFloat
        switch spec {
        case .standard:
            raw = defaultColumnWidth ?? proportionalColumnWidth(
                0.5, viewportWidth: viewportWidth, padding: padding, gap: gap
            )
        case .proportion(let value):
            raw = proportionalColumnWidth(value, viewportWidth: viewportWidth, padding: padding, gap: gap)
        case .points(let value):
            raw = value
        }
        return max(raw, minimumColumnWidth)
    }
}

public enum LayoutError: Error, Equatable, Sendable {
    case invalidViewport
    case invalidConfiguration
}

/// Plan §9 result. `frames` covers every window in non-empty columns, in
/// absolute coordinates against `viewport.min` shifted by `viewportOffset` —
/// ready for the reconciler without further math. `contentWidth` is the full
/// strip width including padding; `viewportOffset` is the clamped offset the
/// frames were computed with (echo it back into workspace state).
public struct LayoutResult: Equatable, Sendable {
    public let frames: [WindowID: CGRect]
    public let contentWidth: CGFloat
    public let viewportOffset: CGFloat
}

public protocol LayoutEngine {
    func calculate(workspace: Workspace, viewport: CGRect) throws -> LayoutResult
}

/// Plan §17: floating and fullscreen windows never enter the strip. Filter
/// columns to tiled members (unknown IDs count as tiled — workspace
/// membership implies a managed window), dropping emptied columns so the
/// strip compacts. Focus indices are clamped, never invented; the engine
/// ignores focus anyway, it only needs positions.
public func tilingWorkspace(
    from workspace: Workspace,
    modes: [WindowID: WindowMode]
) -> Workspace {
    var filtered = workspace
    filtered.columns = workspace.columns.compactMap { column in
        var kept = column
        kept.windows = column.windows.filter { modes[$0, default: .tiled] == .tiled }
        return kept.windows.isEmpty ? nil : kept
    }
    if filtered.columns.isEmpty {
        filtered.focusedColumn = 0
    } else {
        filtered.focusedColumn = min(max(workspace.focusedColumn, 0), filtered.columns.count - 1)
    }
    return filtered
}

/// Plan §9 scrollable column engine. Explicitly NOT BSP: the workspace is a
/// horizontal strip (`Column 1 | Column 2 | …`) and the monitor is a viewport
/// over it. Windows inside one column share its height equally. Appending or
/// removing a column never moves columns to its left.
///
/// The engine is total except for invalid inputs: every emitted frame is
/// finite and positive (an AX requirement). Off-viewport frames are still
/// emitted — skipping them is the reconciler's job (Phase 8), since macOS
/// may refuse writes outside the visible area.
public struct ScrollableLayoutEngine: LayoutEngine, Sendable {
    public let config: LayoutConfig
    /// FI-02 learned per-window minimum sizes (0 in a dimension = unknown).
    /// A column is at least as wide as its widest member's minimum (capped
    /// to the usable viewport), and stacked heights honour minimum heights
    /// where the column can afford them.
    public let minimumSizes: [WindowID: CGSize]

    public init(config: LayoutConfig = LayoutConfig(), minimumSizes: [WindowID: CGSize] = [:]) {
        self.config = config
        self.minimumSizes = minimumSizes
    }

    public func calculate(workspace: Workspace, viewport: CGRect) throws -> LayoutResult {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0
        else {
            throw LayoutError.invalidViewport
        }
        guard config.padding.isFinite, config.gap.isFinite,
              config.padding >= 0, config.gap >= 0,
              config.minimumColumnWidth.isFinite, config.minimumColumnWidth > 0,
              config.defaultColumnWidth.map({ $0.isFinite && $0 > 0 }) ?? true
        else {
            throw LayoutError.invalidConfiguration
        }
        let usableHeight = viewport.height - config.padding * 2
        guard usableHeight > 0 else {
            throw LayoutError.invalidViewport
        }

        var widths: [CGFloat] = []
        var framedColumns: [Column] = []
        for column in workspace.columns where !column.windows.isEmpty {
            let spec = config.resolvedWidth(of: column.widthSpec, viewportWidth: viewport.width)
            let learned = column.windows.map { minimumSizes[$0]?.width ?? 0 }.max() ?? 0
            let usableWidth = max(viewport.width - config.padding * 2, config.minimumColumnWidth)
            widths.append(max(spec, min(learned, usableWidth)))
            framedColumns.append(column)
        }

        let pad = config.padding
        let gap = config.gap
        let contentWidth: CGFloat = framedColumns.isEmpty
            ? 0
            : widths.reduce(0, +) + gap * CGFloat(framedColumns.count - 1) + pad * 2
        let maxOffset = max(0, contentWidth - viewport.width)
        let requested = workspace.viewportOffset.isFinite ? workspace.viewportOffset : 0
        let offset = min(max(requested, 0), maxOffset)

        var frames: [WindowID: CGRect] = [:]
        var cursor = pad
        for (index, column) in framedColumns.enumerated() {
            let width = widths[index]
            let count = column.windows.count
            let distributable = usableHeight - gap * CGFloat(count - 1)
            let heights = distributeHeights(
                available: distributable,
                weights: column.windows.map { column.heightWeights[$0] ?? 1 },
                minimums: column.windows.map { minimumSizes[$0]?.height ?? 0 }
            )
            var y = viewport.minY + pad
            for (winID, rawHeight) in zip(column.windows, heights) {
                let height = max(rawHeight, 1)
                frames[winID] = CGRect(
                    x: viewport.minX + cursor - offset,
                    y: y,
                    width: width,
                    height: height
                )
                y += height + gap
            }
            cursor += width + gap
        }
        return LayoutResult(frames: frames, contentWidth: contentWidth, viewportOffset: offset)
    }
}

/// Niri proportion semantics: a column of proportion `p` takes that share of
/// the strip after padding, so `1/p` such columns plus their gaps fill the
/// viewport exactly (two 0.5 columns never overflow by a gap).
public func proportionalColumnWidth(
    _ proportion: CGFloat, viewportWidth: CGFloat, padding: CGFloat, gap: CGFloat
) -> CGFloat {
    proportion * (viewportWidth - padding * 2 + gap) - gap
}
