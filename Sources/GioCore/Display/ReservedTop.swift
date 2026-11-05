import CoreGraphics

/// SB-01 `[layout] reserved-top`: a display's usable frame for layout: its
/// macOS visible frame (Cocoa, y up: the menu bar, when shown, and the Dock
/// are already outside it) with `reservedTop` points taken off the top edge
/// (`maxY`) for a custom bar. It keeps at least half the visible height.
/// The host applies it to every display's visible frame, so scrolling,
/// dwindle, maximize and fill-empty-space all lay out below the band;
/// fullscreen gets it back (`fullscreenFrame(display:usable:gap:reservedTop:)`).
public func usableFrame(visible: CGRect, reservedTop: CGFloat) -> CGRect {
    let inset = min(max(reservedTop, 0), visible.height / 2)
    guard inset > 0 else {
        return visible
    }
    return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height - inset)
}
