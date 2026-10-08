import CoreGraphics
import Foundation

// SM-08: during a snapshot flight the live focus ring and dim are hidden
// (they would sit apart from the moving images); the overlay draws them on
// its own layers instead, with the same rules, width, color, strength and
// corner radius, so nothing changes when the live ones take over at the end.

/// The ring around the focused window's layer.
public struct OverlayRing: Equatable, Sendable {
    public var id: WindowID
    public var width: CGFloat
    public var color: ThemeColor

    public init(id: WindowID, width: CGFloat, color: ThemeColor) {
        self.id = id
        self.width = width
        self.color = color
    }
}

/// The black fill over the unfocused tiled windows' layers.
public struct OverlayDim: Equatable, Sendable {
    public var ids: Set<WindowID>
    public var strength: Double

    public init(ids: Set<WindowID>, strength: Double) {
        self.ids = ids
        self.strength = strength
    }
}

public struct OverlayDecorations: Equatable, Sendable {
    public var ring: OverlayRing?
    public var dim: OverlayDim?

    public static let none = OverlayDecorations(ring: nil, dim: nil)

    public init(ring: OverlayRing?, dim: OverlayDim?) {
        self.ring = ring
        self.dim = dim
    }
}

/// `focused` is the focused window as the ring sees it (its frame is the one
/// it lands on); `tiled` are the tiled, non-minimized windows of the flight.
/// Ring: exactly the live rule (`focusRingState`). Dim: the other tiled
/// windows at the configured strength, and nothing without a visible
/// focused window (no window to keep lit), like `focusDimRegions`.
public func overlayDecorations(
    focus: FocusSectionConfig, ring: FocusRingSectionConfig, theme: GioTheme?,
    focusedID: WindowID?, focused: FocusRingWindow?, tiled: Set<WindowID>,
    displays: [CGRect], fullscreenGap: CGFloat
) -> OverlayDecorations {
    guard let focusedID, let focused else {
        return .none
    }
    switch focus.indicator {
    case .none:
        return .none
    case .ring:
        guard case .shown(let geometry) = focusRingState(
            config: ring, theme: theme, focused: focused, displays: displays, fullscreenGap: fullscreenGap
        ) else {
            return .none
        }
        return OverlayDecorations(ring: OverlayRing(id: focusedID, width: geometry.width, color: geometry.color), dim: nil)
    case .dim:
        guard let frame = focused.frame, !focused.isMinimized, focusIndicatorVisible(frame, on: displays) else {
            return .none
        }
        let dimmed = tiled.subtracting([focusedID])
        guard !dimmed.isEmpty else {
            return .none
        }
        return OverlayDecorations(ring: nil, dim: OverlayDim(ids: dimmed, strength: focus.dimStrength))
    }
}
