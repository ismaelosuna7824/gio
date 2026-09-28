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

    public init(
        gaps: CGFloat = 8,
        padding: CGFloat = 8,
        defaultColumnWidthFraction: CGFloat? = 0.5,
        defaultColumnWidthPoints: CGFloat? = nil,
        centerFocusedColumn: Bool = true
    ) {
        self.gaps = gaps
        self.padding = padding
        self.defaultColumnWidthFraction = defaultColumnWidthFraction
        self.defaultColumnWidthPoints = defaultColumnWidthPoints
        self.centerFocusedColumn = centerFocusedColumn
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
    /// Consumed by Phase 18 work.
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
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
            return fraction * viewportWidth
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
