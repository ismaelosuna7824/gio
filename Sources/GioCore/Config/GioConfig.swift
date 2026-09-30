import CoreGraphics
import Foundation

/// Single version source, bumped per release milestone.
public let gioVersion = "0.1.0-alpha"

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

    public init(
        gaps: CGFloat = 8,
        padding: CGFloat = 8,
        defaultColumnWidthFraction: CGFloat? = 0.5,
        defaultColumnWidthPoints: CGFloat? = nil,
        centerFocusedColumn: CenterFocusedColumnMode = .never,
        presetColumnWidths: [ColumnWidthSpec] = defaultPresetColumnWidths,
        fullscreenGap: CGFloat? = nil
    ) {
        self.fullscreenGap = fullscreenGap
        self.gaps = gaps
        self.padding = padding
        self.defaultColumnWidthFraction = defaultColumnWidthFraction
        self.defaultColumnWidthPoints = defaultColumnWidthPoints
        self.centerFocusedColumn = centerFocusedColumn
        self.presetColumnWidths = presetColumnWidths
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

    public init(focusFollowsMouse: Bool = false, mouseFollowsFocus: Bool = true) {
        self.focusFollowsMouse = focusFollowsMouse
        self.mouseFollowsFocus = mouseFollowsFocus
    }
}

/// NF-04: how motion is timed.
public enum MotionCurveKind: String, Equatable, Sendable {
    case spring
    case easeOut = "ease-out"
}

public struct AnimationsSectionConfig: Equatable, Sendable {
    public static let durationRange = 0...1000

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

    public init(
        enabled: Bool = true, durationMilliseconds: Int = 200,
        curve: MotionCurveKind = .spring,
        springDampingRatio: Double = SpringParameters.niri.dampingRatio,
        springStiffness: Double = SpringParameters.niri.stiffness,
        resize: ResizeMode = .never,
        renderer: RendererKind = .ax
    ) {
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
    public var logging: LoggingSectionConfig
    /// Ordered file bindings; applied over dispatcher defaults.
    public var keybindings: [(HotkeyCombo, HotkeyAction)]
    public var rules: [WindowRule]

    public init(
        layout: LayoutSectionConfig = LayoutSectionConfig(),
        behavior: BehaviorSectionConfig = BehaviorSectionConfig(),
        animations: AnimationsSectionConfig = AnimationsSectionConfig(),
        focusRing: FocusRingSectionConfig = FocusRingSectionConfig(),
        logging: LoggingSectionConfig = LoggingSectionConfig(),
        keybindings: [(HotkeyCombo, HotkeyAction)] = [],
        rules: [WindowRule] = []
    ) {
        self.layout = layout
        self.behavior = behavior
        self.animations = animations
        self.focusRing = focusRing
        self.logging = logging
        self.keybindings = keybindings
        self.rules = rules
    }

    /// Resolve to engine input. Fraction wins when set, else absolute,
    /// else engine default (nil).
    public func resolveDefaultColumnWidth(viewportWidth: CGFloat) -> CGFloat? {
        if let fraction = layout.defaultColumnWidthFraction {
            return proportionalColumnWidth(
                fraction, viewportWidth: viewportWidth, padding: layout.padding, gap: layout.gaps
            )
        }
        return layout.defaultColumnWidthPoints
    }

    public func makeLayoutConfig(viewportWidth: CGFloat) -> LayoutConfig {
        LayoutConfig(
            padding: layout.padding,
            gap: layout.gaps,
            defaultColumnWidth: resolveDefaultColumnWidth(viewportWidth: viewportWidth),
            fullscreenGap: layout.resolvedFullscreenGap
        )
    }

    /// Defaults first, config bindings overriding in file order.
    public func makeDispatcher() -> HotkeyDispatcher {
        var dispatcher = HotkeyDispatcher()
        for (combo, action) in keybindings {
            dispatcher.bind(action, to: combo)
        }
        return dispatcher
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
