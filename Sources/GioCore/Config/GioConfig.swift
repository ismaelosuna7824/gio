import CoreGraphics
import Foundation

/// Plan §20 configuration model. Mirrors `~/.config/gio/config.toml`.
/// Every flag is parsed, validated and stored — never silently dropped — with
/// its consumer named in comments.
public struct LayoutSectionConfig: Equatable, Sendable {
    public static let fullscreenGapRange = 0...64

    public var gaps: CGFloat
    public var padding: CGFloat
    /// Inset around a fullscreen window; nil follows `gaps`.
    public var fullscreenGap: CGFloat?
    /// Fraction of viewport width when 0 < v ≤ 1 (plan default 0.5 = half).
    public var defaultColumnWidthFraction: CGFloat?
    /// Absolute points when > 1. At most one of the two is set.
    public var defaultColumnWidthPoints: CGFloat?
    /// Niri `center-focused-column`; consumed by the reveal step (HD-04).
    public var centerFocusedColumn: CenterFocusedColumnMode
    /// Widths `switch-preset-column-width` cycles through (Niri
    /// `preset-column-widths`): fractions when ≤ 1, points otherwise.
    public var presetColumnWidths: [ColumnWidthSpec]
    /// NC-08: heights `switch-preset-window-height` cycles the focused
    /// window of a stacked column through (niri `preset-window-heights`):
    /// fractions of the usable height when ≤ 1, points otherwise.
    public var presetWindowHeights: [ColumnWidthSpec]
    /// SW-01: a workspace with one tiled window shows it at the full strip
    /// width, like `maximize-column`; consumed by the layout engine.
    public var maximizeSingleWindow: Bool
    /// NC-13 niri `always-center-single-column`: a workspace with a single
    /// column shows it in the middle; consumed by the layout engine.
    public var alwaysCenterSingleColumn: Bool
    /// DW-03 `default-layout`: the layout new workspaces start with;
    /// consumed by `WorkspaceManager.applyLayoutDefaults`.
    public var defaultLayout: WorkspaceLayoutKind
    /// `new-window-position`: where a live arrival's column lands in a
    /// scrolling strip; consumed by `placeArrival` through `DiscoveryService`.
    public var newWindowPosition: NewWindowPosition

    public init(
        gaps: CGFloat = 8,
        padding: CGFloat = 8,
        defaultColumnWidthFraction: CGFloat? = 0.5,
        defaultColumnWidthPoints: CGFloat? = nil,
        centerFocusedColumn: CenterFocusedColumnMode = .never,
        presetColumnWidths: [ColumnWidthSpec] = defaultPresetColumnWidths,
        fullscreenGap: CGFloat? = nil,
        maximizeSingleWindow: Bool = true,
        presetWindowHeights: [ColumnWidthSpec] = defaultPresetWindowHeights,
        alwaysCenterSingleColumn: Bool = false,
        defaultLayout: WorkspaceLayoutKind = .scrolling,
        newWindowPosition: NewWindowPosition = .end
    ) {
        self.fullscreenGap = fullscreenGap
        self.gaps = gaps
        self.padding = padding
        self.defaultColumnWidthFraction = defaultColumnWidthFraction
        self.defaultColumnWidthPoints = defaultColumnWidthPoints
        self.centerFocusedColumn = centerFocusedColumn
        self.presetColumnWidths = presetColumnWidths
        self.presetWindowHeights = presetWindowHeights
        self.maximizeSingleWindow = maximizeSingleWindow
        self.alwaysCenterSingleColumn = alwaysCenterSingleColumn
        self.defaultLayout = defaultLayout
        self.newWindowPosition = newWindowPosition
    }
}

/// DW-03 `[dwindle]`: consumed by the dwindle engine (`makeLayoutConfig`)
/// and the tree's insertion (`layoutDefaults`).
public struct DwindleSectionConfig: Equatable, Sendable {
    public static let splitRatioRange = 0.1...1.9
    public static let splitWidthMultiplierRange = 0.1...10.0

    /// `default-split-ratio`: a new split's ratio (the first, existing
    /// window's share times two; 1 = half and half).
    public var defaultSplitRatio: CGFloat
    /// `split-width-multiplier`: side by side when `width >= height * m`.
    public var splitWidthMultiplier: CGFloat

    public init(defaultSplitRatio: CGFloat = 1, splitWidthMultiplier: CGFloat = 1) {
        self.defaultSplitRatio = defaultSplitRatio
        self.splitWidthMultiplier = splitWidthMultiplier
    }
}

extension LayoutSectionConfig {
    /// The gap fullscreen windows keep: the explicit key, else `gaps`.
    public var resolvedFullscreenGap: CGFloat { fullscreenGap ?? gaps }
}

public struct BehaviorSectionConfig: Equatable, Sendable {
    /// Consumed by the session host (HD-04): hover focus and cursor warp.
    public var focusFollowsMouse: Bool
    public var mouseFollowsFocus: Bool
    /// MM-06 `move-crosses-monitor-at-edge`: `move-column-left/right` at the
    /// strip's edge send the column to the neighbouring display, like
    /// `move-column-*-or-to-monitor-*`; NC-14: the window move
    /// (`consume-or-expel-window-*`, `move-up/down`, `gio move`) at the
    /// workspace's edge sends the window (`moveWindowOrToDisplay`).
    public var moveCrossesMonitorAtEdge: Bool

    public init(focusFollowsMouse: Bool = false, mouseFollowsFocus: Bool = true, moveCrossesMonitorAtEdge: Bool = false) {
        self.focusFollowsMouse = focusFollowsMouse
        self.mouseFollowsFocus = mouseFollowsFocus
        self.moveCrossesMonitorAtEdge = moveCrossesMonitorAtEdge
    }
}

/// NF-04: how motion is timed.
public enum MotionCurveKind: String, Equatable, Sendable {
    case spring
    case easeOut = "ease-out"
}

public struct AnimationsSectionConfig: Equatable, Sendable {
    public static let durationRange = 0...1000
    /// NA-04: `[animations.window-open] offset`, in points.
    public static let openOffsetRange = 0.0...200.0

    /// Scroll/focus motion (MO-04). Off means every reflow is instant.
    public var enabled: Bool
    /// Length of one animation, clamped to `durationRange` by the parser.
    public var durationMilliseconds: Int
    /// NF-04: `spring` (default) ignores `durationMilliseconds` except that
    /// 0 still means instant; `ease-out` uses it as the flight length.
    public var curve: MotionCurveKind
    public var springDampingRatio: Double
    public var springStiffness: Double
    /// PA-06: whether growing windows interpolate their size during flight.
    public var resize: ResizeMode
    /// SM-01: `snapshot` (default) needs Screen Recording; falls back to `ax`.
    public var renderer: RendererKind
    /// When the focused window that grows gets its final size: `start`
    /// (default, first frame) or `end` (FI-03, final pass).
    public var focusedGrow: FocusedGrowMode
    /// Maximize-column grows a single-window column by pressing the app's own
    /// zoom instead of writing a new size (default on); other cases and apps
    /// without a usable zoom keep the ordinary write.
    public var nativeZoom: Bool
    /// NA-03: `[animations.window-close] ghost`: a closing window in view
    /// fades out from its cached image (needs Screen Recording). Off by default.
    public var closeGhost: Bool
    /// NA-04: `[animations.<name>]` tables, keyed by Niri name.
    public var overrides: [AnimationKind: AnimationOverride]
    /// NA-02/NA-04: `[animations.window-open] offset`: how far below its tile
    /// a new window starts (0: no entry flight).
    public var openOffset: Double

    public init(
        enabled: Bool = true, durationMilliseconds: Int = 200,
        curve: MotionCurveKind = .spring,
        springDampingRatio: Double = SpringParameters.niri.dampingRatio,
        springStiffness: Double = SpringParameters.niri.stiffness,
        resize: ResizeMode = .never,
        renderer: RendererKind = .snapshot,
        focusedGrow: FocusedGrowMode = .start,
        nativeZoom: Bool = true,
        closeGhost: Bool = false,
        overrides: [AnimationKind: AnimationOverride] = [:],
        openOffset: Double = 24
    ) {
        self.overrides = overrides
        self.openOffset = openOffset
        self.nativeZoom = nativeZoom
        self.closeGhost = closeGhost
        self.focusedGrow = focusedGrow
        self.resize = resize
        self.renderer = renderer
        self.enabled = enabled
        self.durationMilliseconds = durationMilliseconds
        self.curve = curve
        self.springDampingRatio = springDampingRatio
        self.springStiffness = springStiffness
    }

    public var spring: SpringParameters {
        SpringParameters(
            dampingRatio: springDampingRatio, stiffness: springStiffness,
            epsilon: SpringParameters.niri.epsilon
        )
    }

    public var duration: TimeInterval { TimeInterval(durationMilliseconds) / 1000 }

    /// Disabled or zero-length animations keep the instant behavior.
    public var isActive: Bool { enabled && durationMilliseconds > 0 }
}

/// PA-01: minimum severity written to the ring and `gio.log`.
public struct LoggingSectionConfig: Equatable, Sendable {
    public var level: LogLevel

    public init(level: LogLevel = .info) {
        self.level = level
    }
}

public struct GioConfig: Sendable {
    public var layout: LayoutSectionConfig
    public var behavior: BehaviorSectionConfig
    public var animations: AnimationsSectionConfig
    /// NF-01: consumed by the session host (focus ring overlay).
    public var focusRing: FocusRingSectionConfig
    /// NF-06: which focus indicator runs (the ring by default, NF-08) and the dim strength.
    public var focus: FocusSectionConfig
    public var logging: LoggingSectionConfig
    /// Ordered file bindings; applied over dispatcher defaults. A combo set
    /// to `"none"` later in the file is not here (see `unboundKeys`).
    public var keybindings: [(HotkeyCombo, HotkeyAction)]
    /// DA-07: combos set to `"none"` (and not bound again further down):
    /// they do nothing, defaults included.
    public var unboundKeys: [HotkeyCombo]
    public var rules: [WindowRule]
    /// NW-01: `[[workspace]]` entries in file order (empty: no named
    /// workspaces, the pre-NW behaviour).
    public var workspaces: [WorkspaceDefinition]
    /// DW-03 `[dwindle]`.
    public var dwindle: DwindleSectionConfig
    /// TG-02: trackpad gestures.
    public var gestures: GesturesSectionConfig

    public init(
        layout: LayoutSectionConfig = LayoutSectionConfig(),
        behavior: BehaviorSectionConfig = BehaviorSectionConfig(),
        animations: AnimationsSectionConfig = AnimationsSectionConfig(),
        focusRing: FocusRingSectionConfig = FocusRingSectionConfig(),
        focus: FocusSectionConfig = FocusSectionConfig(),
        logging: LoggingSectionConfig = LoggingSectionConfig(),
        keybindings: [(HotkeyCombo, HotkeyAction)] = [],
        unboundKeys: [HotkeyCombo] = [],
        rules: [WindowRule] = [],
        workspaces: [WorkspaceDefinition] = [],
        dwindle: DwindleSectionConfig = DwindleSectionConfig(),
        gestures: GesturesSectionConfig = GesturesSectionConfig()
    ) {
        self.gestures = gestures
        self.workspaces = workspaces
        self.layout = layout
        self.behavior = behavior
        self.animations = animations
        self.focusRing = focusRing
        self.focus = focus
        self.logging = logging
        self.keybindings = keybindings
        self.unboundKeys = unboundKeys
        self.rules = rules
        self.dwindle = dwindle
    }

    /// DW-03: what `WorkspaceManager.applyLayoutDefaults` receives.
    public var layoutDefaults: WorkspaceLayoutDefaults {
        WorkspaceLayoutDefaults(kind: layout.defaultLayout, splitRatio: dwindle.defaultSplitRatio)
    }

    /// Engine input, independent of any display: a fraction stays a
    /// proportion that each display resolves against its own viewport
    /// (MM-01); points are absolute. The fraction wins when both are set;
    /// neither leaves the engine default (half the viewport).
    public func makeLayoutConfig() -> LayoutConfig {
        let fraction = layout.defaultColumnWidthFraction
        return LayoutConfig(
            padding: layout.padding,
            gap: layout.gaps,
            defaultColumnWidth: fraction == nil ? layout.defaultColumnWidthPoints : nil,
            defaultColumnProportion: fraction ?? 0.5,
            fullscreenGap: layout.resolvedFullscreenGap,
            maximizeSingleWindow: layout.maximizeSingleWindow,
            alwaysCenterSingleColumn: layout.alwaysCenterSingleColumn,
            dwindle: DwindleSettings(
                splitRatio: dwindle.defaultSplitRatio, splitWidthMultiplier: dwindle.splitWidthMultiplier
            ),
            centerFocusedColumn: layout.centerFocusedColumn
        )
    }

    /// Defaults first, `"none"` combos removed, config bindings overriding
    /// in file order.
    public func makeDispatcher() -> HotkeyDispatcher {
        var dispatcher = HotkeyDispatcher()
        for combo in unboundKeys {
            dispatcher.unbind(combo)
        }
        for (combo, action) in keybindings {
            dispatcher.bind(action, to: combo)
        }
        return dispatcher
    }
}

/// PA-12: written out because `keybindings` holds tuples, which are not
/// Equatable; they compare element-wise, in order. Every stored property
/// takes part (`GioConfigEqualityTests` counts them).
extension GioConfig: Equatable {
    public static func == (lhs: GioConfig, rhs: GioConfig) -> Bool {
        guard lhs.layout == rhs.layout, lhs.behavior == rhs.behavior, lhs.animations == rhs.animations,
              lhs.focusRing == rhs.focusRing, lhs.focus == rhs.focus, lhs.logging == rhs.logging,
              lhs.unboundKeys == rhs.unboundKeys, lhs.rules == rhs.rules, lhs.workspaces == rhs.workspaces,
              lhs.dwindle == rhs.dwindle, lhs.gestures == rhs.gestures
        else {
            return false
        }
        return lhs.keybindings.elementsEqual(rhs.keybindings) { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

public func defaultGioConfig() -> GioConfig {
    GioConfig()
}

/// Missing file means first run: silent defaults. Present-but-invalid means
/// defaults plus the error messages — an invalid config never breaks the WM.
public func loadGioConfig(at path: String? = nil) -> (config: GioConfig, messages: [String]) {
    let resolved = path ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/config.toml")
    guard let text = try? String(contentsOfFile: resolved, encoding: .utf8) else {
        return (defaultGioConfig(), [])
    }
    switch parseGioConfig(text) {
    case .success(let (parsed, warnings)):
        return (parsed, warnings)
    case .failure(let errors):
        return (defaultGioConfig(), errors.messages)
    }
}
