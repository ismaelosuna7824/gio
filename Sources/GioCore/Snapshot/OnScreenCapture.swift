import CoreGraphics
import Foundation

// FX-11: a window drawn with a see-through material (a blurred pane,
// vibrancy) has no such pixels of its own: the WindowServer blurs what is
// behind it when it composites the screen. A desktop-independent capture
// renders the window alone, so the material comes out as a flat fallback
// colour (live: Tern's pane, real (32, 40, 40), image (43, 43, 45)) and the
// flight showed another window for its whole length. A window fully on one
// display that nothing covers is captured as the display shows it (a crop of
// the composited display, Gio's own panels left out) instead.

/// One on-screen WindowServer window, front to back (the order of the
/// on-screen list), any layer, Cocoa frame.
public struct StackedServerWindow: Equatable, Sendable {
    public let windowID: UInt32
    public let pid: pid_t
    public let layer: Int
    public let alpha: Double
    public let frame: CGRect

    public init(windowID: UInt32, pid: pid_t, layer: Int, alpha: Double, frame: CGRect) {
        self.windowID = windowID
        self.pid = pid
        self.layer = layer
        self.alpha = alpha
        self.frame = frame
    }
}

/// The windows to capture as the display shows them, with the index of
/// their display in `displays` (Cocoa frames). A window qualifies when it is
/// captured at full resolution, lies within one display (1 pt slack: a
/// parked window's sliver does not), is on screen (`windowNumbers` matched
/// it to `stack`), and no window in front of it covers any of it, Gio's own
/// panels (`ownPid`, left out of the capture) and fully transparent windows
/// aside. Every other window keeps the desktop-independent capture.
public func snapshotOnScreenCaptures(
    frames: [WindowID: CGRect], windowNumbers: [WindowID: UInt32], stack: [StackedServerWindow],
    displays: [CGRect], ownPid: pid_t, half: Set<WindowID>
) -> [WindowID: Int] {
    var result: [WindowID: Int] = [:]
    for (id, frame) in frames where !half.contains(id) {
        guard let number = windowNumbers[id],
              let position = stack.firstIndex(where: { $0.windowID == number }),
              let display = displays.firstIndex(where: { $0.insetBy(dx: -1, dy: -1).contains(frame) })
        else {
            continue
        }
        let covered = stack[..<position].contains { front in
            guard front.pid != ownPid, front.alpha > 0.01 else {
                return false
            }
            let overlap = front.frame.intersection(frame)
            return !overlap.isNull && overlap.width > 1 && overlap.height > 1
        }
        if !covered {
            result[id] = display
        }
    }
    return result
}

/// The window's rectangle in its display's top-left points, the
/// `sourceRect` of a display capture.
public func snapshotDisplayCrop(window: CGRect, display: CGRect) -> CGRect {
    CGRect(
        x: window.minX - display.minX, y: display.maxY - window.maxY,
        width: window.width, height: window.height
    )
}
