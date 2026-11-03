import CoreGraphics

/// One on-screen window-server surface, as Gio needs it to notice macOS's
/// own overview of the windows (WC-18). `bounds` are the surface's global
/// display coordinates in points.
public struct OnScreenSurface: Equatable, Sendable {
    public var owner: String
    public var level: Int
    public var bounds: CGRect

    public init(owner: String, level: Int, bounds: CGRect) {
        self.owner = owner
        self.level = level
        self.bounds = bounds
    }
}

/// WC-18: whether macOS is showing its own overview of the windows: Mission
/// Control and App Exposé put a screen-sized **shield** (level 19, owned by
/// the `WindowManager` process) in front of everything, and Mission Control
/// adds the Spaces bar (level 14) on top. Gio's focus ring and dim are
/// separate panels that the WindowServer does not move with that surface, so
/// during the overview they would sit at the windows' real frames as empty
/// borders over the scaled windows.
///
/// The shield also comes in small sizes that are not an overview (a Stage
/// Manager stage icon is 66×82 and off-screen while the strip is hidden), and
/// any other app can own a level-19 surface, so both are ignored.
public func systemOverviewShowing(_ surfaces: [OnScreenSurface], screens: [CGRect]) -> Bool {
    surfaces.contains { surface in
        guard surface.owner == "WindowManager", surface.level == 19,
              surface.bounds.width > 0, surface.bounds.height > 0
        else {
            return false
        }
        return screens.contains { screen in
            surface.bounds.width >= screen.width && surface.bounds.height >= screen.height
        }
    }
}
