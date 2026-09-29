import CoreGraphics
import Foundation

/// Single version source, bumped per release milestone.
public let gioVersion = "0.1.0-alpha"

/// Plan §20 configuration model. Mirrors `~/.config/gio/config.toml`.
/// Flags the engine does not consume yet (`centerFocusedColumn`,
/// behaviors, animations) are parsed, validated and stored — never silently
/// dropped — with their consumer named in comments.
public struct LayoutSectionConfig: Equatable, Sendable {
    public var gaps: CGFloat
    public var padding: CGFloat
    /// Fraction of viewport width when 0 < v ≤ 1 (plan default 0.5 = half).
    public var defaultColumnWidthFraction: CGFloat?
    /// Absolute points when > 1. At most one of the two is set.
    public var defaultColumnWidthPoints: CGFloat?
    /// Parsed and validated; consumed by future engine centering work.
    public var centerFocusedColumn: Bool
    /// Widths `switch-preset-column-width` cycles through (Niri
    /// `preset-column-widths`): fractions when ≤ 1, points otherwise.
    public var presetColumnWidths: [ColumnWidthSpec]

    public init(
        gaps: CGFloat = 8,
        padding: CGFloat = 8,
        defaultColumnWidthFraction: CGFloat? = 0.5,
        defaultColumnWidthPoints: CGFloat? = nil,
        centerFocusedColumn: Bool = true,
        presetColumnWidths: [ColumnWidthSpec] = defaultPresetColumnWidths
    ) {
        self.gaps = gaps
        self.padding = padding
        self.defaultColumnWidthFraction = defaultColumnWidthFraction
        self.defaultColumnWidthPoints = defaultColumnWidthPoints
        self.centerFocusedColumn = centerFocusedColumn
        self.presetColumnWidths = presetColumnWidths
    }
}

public struct BehaviorSectionConfig: Equatable, Sendable {
    /// Consumed by the future event/daemon layer, not by layout.
    public var focusFollowsMouse: Bool
    public var mouseFollowsFocus: Bool

    public init(focusFollowsMouse: Bool = false, mouseFollowsFocus: Bool = true) {
        self.focusFollowsMouse = focusFollowsMouse
        self.mouseFollowsFocus = mouseFollowsFocus
    }
}

public struct AnimationsSectionConfig: Equatable, Sendable {
    public static let durationRange = 0...1000

    /// Scroll/focus motion (MO-04). Off means every reflow is instant.
    public var enabled: Bool
    /// Length of one animation, clamped to `durationRange` by the parser.
    public var durationMilliseconds: Int

    public init(enabled: Bool = true, durationMilliseconds: Int = 200) {
        self.enabled = enabled
        self.durationMilliseconds = durationMilliseconds
    }

    public var duration: TimeInterval { TimeInterval(durationMilliseconds) / 1000 }

    /// Disabled or zero-length animations keep the instant behavior.
    public var isActive: Bool { enabled && durationMilliseconds > 0 }
}

public struct GioConfig: Sendable {
    public var layout: LayoutSectionConfig
    public var behavior: BehaviorSectionConfig
    public var animations: AnimationsSectionConfig
    /// Ordered file bindings; applied over dispatcher defaults.
    public var keybindings: [(HotkeyCombo, HotkeyAction)]
    public var rules: [WindowRule]

    public init(
        layout: LayoutSectionConfig = LayoutSectionConfig(),
        behavior: BehaviorSectionConfig = BehaviorSectionConfig(),
        animations: AnimationsSectionConfig = AnimationsSectionConfig(),
        keybindings: [(HotkeyCombo, HotkeyAction)] = [],
        rules: [WindowRule] = []
    ) {
        self.layout = layout
        self.behavior = behavior
        self.animations = animations
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
            defaultColumnWidth: resolveDefaultColumnWidth(viewportWidth: viewportWidth)
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
