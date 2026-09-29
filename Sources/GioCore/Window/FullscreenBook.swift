import CoreGraphics
import Foundation

/// Frame of a fullscreen window on one display. Decision (NC-03): it spans
/// the display's full width and reaches down to the display's bottom edge
/// (covering the Dock area, which never blocks a tiler's windows), but stops
/// under the menu bar — macOS refuses window frames that overlap it, and Gio
/// never uses native fullscreen Spaces. `usable` is the display's
/// visible frame (Cocoa, y up), so its `maxY` is the menu bar's lower edge.
public func fullscreenFrame(display: CGRect, usable: CGRect) -> CGRect {
    let top = min(max(usable.maxY, display.minY), display.maxY)
    return CGRect(
        x: display.minX, y: display.minY, width: display.width, height: top - display.minY
    )
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

    /// Leave fullscreen for every recorded window not in `focused` (focusing
    /// away restores the layout). Records whose window vanished or already
    /// left fullscreen by another route are dropped without touching the
    /// registry. Returns the windows actually restored, in ID order.
    @discardableResult
    public mutating func release(keeping focused: Set<WindowID>, registry: WindowRegistry) -> [WindowID] {
        var restored: [WindowID] = []
        for id in records.keys.sorted() {
            guard let record = records[id] else {
                continue
            }
            guard registry.find(id)?.mode == .fullscreen else {
                records.removeValue(forKey: id)
                continue
            }
            if !focused.contains(id) {
                try? registry.endFullscreen(record)
                records.removeValue(forKey: id)
                restored.append(id)
            }
        }
        return restored
    }

    /// Forget a window that is gone for good.
    public mutating func forget(_ id: WindowID) {
        records.removeValue(forKey: id)
    }
}
