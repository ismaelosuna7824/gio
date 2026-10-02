import CoreGraphics
import Foundation

/// Frame of a fullscreen window on one display. Decision (NC-03): it spans
/// the display's full width and reaches down to the display's bottom edge
/// (covering the Dock area, which never blocks a tiler's windows), but stops
/// under the menu bar — macOS refuses window frames that overlap it, and Gio
/// never uses native fullscreen Spaces. `usable` is the display's
/// visible frame (Cocoa, y up), so its `maxY` is the menu bar's lower edge.
/// `gap` insets the frame on every side (`[layout] fullscreen-gap`), keeping
/// it under the menu bar; it never collapses below zero size.
public func fullscreenFrame(display: CGRect, usable: CGRect, gap: CGFloat = 0) -> CGRect {
    let top = min(max(usable.maxY, display.minY), display.maxY)
    let base = CGRect(
        x: display.minX, y: display.minY, width: display.width, height: top - display.minY
    )
    let inset = min(max(gap, 0), base.width / 2, base.height / 2)
    return base.insetBy(dx: inset, dy: inset)
}

/// Remembers which windows are fullscreen and what to restore. The registry
/// owns the mode; this book owns the `FullscreenRecord`s that `beginFullscreen`
/// hands back, so leaving fullscreen returns each window to its previous
/// mode and frame (its column is untouched throughout).
public struct FullscreenBook: Equatable, Sendable {
    private var records: [WindowID: FullscreenRecord] = [:]

    public init() {}

    public func isFullscreen(_ id: WindowID) -> Bool {
        records[id] != nil
    }

    /// Enter fullscreen on `frame`, or leave it when already recorded.
    /// Returns true when the window is fullscreen afterwards. Unknown IDs
    /// throw (registry rule).
    @discardableResult
    public mutating func toggle(
        _ id: WindowID, registry: WindowRegistry, frame: CGRect
    ) throws -> Bool {
        if let record = records[id] {
            try registry.endFullscreen(record)
            records.removeValue(forKey: id)
            return false
        }
        records[id] = try registry.beginFullscreen(id: id, frame: frame)
        return true
    }

    public mutating func prune(registry: WindowRegistry) {
        for id in records.keys where registry.find(id)?.mode != .fullscreen {
            records.removeValue(forKey: id)
        }
    }

    /// Forget a window that is gone for good.
    public mutating func forget(_ id: WindowID) {
        records.removeValue(forKey: id)
    }
}
