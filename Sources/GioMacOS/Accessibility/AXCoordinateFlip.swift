import CoreGraphics
import Foundation

/// AX speaks top-left origin; `NSScreen` speaks bottom-left. Mixing them
/// tiles windows into the menu bar or Dock, and macOS clamps the write —
/// exactly the systematic y=8→y=39 clamp seen live. This type converts at
/// the adapter boundary so the engine only ever sees Cocoa coordinates.
///
/// The flip needs the FULL display height of the window's own display. RW-09
/// tiles the main display only, so one height suffices; per-display spaces
/// (RW-11) will carry it per window.
public struct AXVerticalFlip: Equatable, Sendable {
    public var displayHeight: CGFloat

    public init(displayHeight: CGFloat) {
        self.displayHeight = displayHeight
    }

    /// Cocoa (bottom-left) → AX (top-left).
    public func toAX(_ cocoa: CGRect) -> CGRect {
        CGRect(
            x: cocoa.origin.x,
            y: displayHeight - cocoa.origin.y - cocoa.size.height,
            width: cocoa.size.width,
            height: cocoa.size.height
        )
    }

    /// AX (top-left) → Cocoa (bottom-left).
    public func toCocoa(_ ax: CGRect) -> CGRect {
        CGRect(
            x: ax.origin.x,
            y: displayHeight - ax.origin.y - ax.size.height,
            width: ax.size.width,
            height: ax.size.height
        )
    }
}
