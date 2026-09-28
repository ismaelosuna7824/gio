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

    public init(config: LayoutConfig = LayoutConfig()) {
        self.config = config
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

        let defaultWidth = config.defaultColumnWidth ?? viewport.width / 2
        var widths: [CGFloat] = []
        var framedColumns: [Column] = []
        for column in workspace.columns where !column.windows.isEmpty {
            let raw = column.width > 0 ? column.width : defaultWidth
            widths.append(max(raw, config.minimumColumnWidth))
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
            let totalWeight = column.windows.reduce(CGFloat(0)) {
                $0 + (column.heightWeights[$1] ?? 1)
            }
            let distributable = usableHeight - gap * CGFloat(count - 1)
            var y = viewport.minY + pad
            for winID in column.windows {
                let share = (column.heightWeights[winID] ?? 1) / totalWeight
                let height = max(distributable * share, 1)
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
