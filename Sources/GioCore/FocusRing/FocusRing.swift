import CoreGraphics
import Foundation

/// NF-01 config: `[focus-ring] enabled / width / active-color`.
public struct FocusRingSectionConfig: Equatable, Sendable {
    public static let widthRange = 0...20
    /// Niri's default focus color.
    public static let defaultColor = ThemeColor(hex: "#7fc8ff")!

    public var enabled: Bool
    /// Ring thickness in points; 0 draws nothing.
    public var width: Int
    /// Explicit color; nil defers to the theme, then to `defaultColor`.
    public var activeColor: ThemeColor?
    /// No ring on a maximized column or a fullscreen window (default). Off
    /// restores the fullscreen ring when the fullscreen gap fits it.
    public var hideWhenMaximized: Bool

    public init(
        enabled: Bool = true, width: Int = 4, activeColor: ThemeColor? = nil, hideWhenMaximized: Bool = true
    ) {
        self.enabled = enabled
        self.width = width
        self.activeColor = activeColor
        self.hideWhenMaximized = hideWhenMaximized
    }

    /// Explicit color, else the theme's active border, else Niri's blue.
    public func resolvedColor(theme: GioTheme? = nil) -> ThemeColor {
        activeColor ?? theme?.borderActive ?? Self.defaultColor
    }
}

/// Corner radius macOS gives windows (approximately); the ring's inner edge
/// follows it so the ring hugs the window.
public let focusRingWindowCornerRadius: CGFloat = 10

/// What the session knows about the focused managed window. `frame` is Gio's
/// own bookkeeping of where the window physically is (Cocoa coordinates), so
/// building the ring never needs an Accessibility call.
public struct FocusRingWindow: Equatable, Sendable {
    public var frame: CGRect?
    public var isMinimized: Bool
    public var isFullscreen: Bool
    /// The focused column is maximized (NC-02 maximize-column).
    public var isMaximized: Bool

    public init(frame: CGRect?, isMinimized: Bool = false, isFullscreen: Bool = false, isMaximized: Bool = false) {
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isMaximized = isMaximized
    }
}

/// Where and how to draw the ring. `frame` is the overlay window's frame:
/// the focused window's frame outset by `width`.
public struct FocusRingGeometry: Equatable, Sendable {
    public var frame: CGRect
    public var width: CGFloat
    public var color: ThemeColor

    public init(frame: CGRect, width: CGFloat, color: ThemeColor) {
        self.frame = frame
        self.width = width
        self.color = color
    }

    /// Path of the stroke in overlay-local coordinates: strokes are centered
    /// on their path, so it sits half a width inside the overlay bounds.
    public var strokeRect: CGRect {
        CGRect(origin: .zero, size: frame.size).insetBy(dx: width / 2, dy: width / 2)
    }

    /// The inner edge keeps the window's radius; the path is half a width out.
    public var strokeCornerRadius: CGFloat {
        focusRingWindowCornerRadius + width / 2
    }
}

public enum FocusRingState: Equatable, Sendable {
    case hidden
    case shown(FocusRingGeometry)

    /// The ring never shows while Gio itself is frontmost (its main window
    /// or the launcher has focus, so no managed window is being worked in).
    public func masked(gioIsFrontmost: Bool) -> FocusRingState {
        gioIsFrontmost ? .hidden : self
    }
}

/// A window with less than this much of its width or height inside a display
/// counts as off-viewport (parked windows keep a 1 pt sliver on screen).
private let minimumVisibleExtent: CGFloat = 24

/// The focus indicators (ring, dim, their overlay copies) draw only for a
/// window with at least 24 pt of width and height inside some display.
public func focusIndicatorVisible(_ frame: CGRect, on displays: [CGRect]) -> Bool {
    displays.contains { display in
        let overlap = display.intersection(frame)
        return !overlap.isNull && overlap.width >= minimumVisibleExtent
            && overlap.height >= minimumVisibleExtent
    }
}

/// Pure decision: the ring for the focused window, or hidden when the feature
/// is off, nothing is focused, the window is minimized, maximized or
/// fullscreen while `hideWhenMaximized` is on, fullscreen without
/// room for it (the ring would be clipped by the display edge and menu bar
/// unless `fullscreenGap` is at least the ring width) or off-viewport
/// (parked, or on a workspace no display shows).
public func focusRingState(
    config: FocusRingSectionConfig, theme: GioTheme? = nil,
    focused: FocusRingWindow?, displays: [CGRect], fullscreenGap: CGFloat = 0
) -> FocusRingState {
    guard config.enabled, config.width > 0, let focused, let frame = focused.frame,
          !focused.isMinimized,
          !(config.hideWhenMaximized && (focused.isMaximized || focused.isFullscreen)),
          !focused.isFullscreen || fullscreenGap >= CGFloat(config.width)
    else {
        return .hidden
    }
    guard focusIndicatorVisible(frame, on: displays) else {
        return .hidden
    }
    let width = CGFloat(config.width)
    return .shown(
        FocusRingGeometry(
            frame: frame.insetBy(dx: -width, dy: -width), width: width,
            color: config.resolvedColor(theme: theme)
        )
    )
}

/// Latest-value hand-off from the session queue to the main thread. `post`
/// keeps only the newest value and answers true exactly when the caller must
/// schedule a drain, so a flood of motion frames leaves at most one main-queue
/// block pending. Values equal to the last posted one are dropped.
public final class LatestValueMailbox<Value: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPosted: Value?
    private var pending: Value?
    private var drainScheduled = false

    public init() {}

    public func post(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value != lastPosted else {
            return false
        }
        lastPosted = value
        pending = value
        guard !drainScheduled else {
            return false
        }
        drainScheduled = true
        return true
    }

    /// Called by the scheduled drain: the newest value, once.
    public func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        drainScheduled = false
        let value = pending
        pending = nil
        return value
    }
}
