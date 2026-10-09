import CoreGraphics
import Foundation

/// Pure form models behind the Settings views: values in, validation
/// problems and `ConfigEdit`s out. Views own no rules of their own.

public func parsePresetList(_ text: String) -> [Double]? {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    var numbers: [Double] = []
    for part in parts {
        guard let number = Double(part), number > 0, number.isFinite else {
            return nil
        }
        numbers.append(number)
    }
    return numbers.isEmpty ? nil : numbers
}

public struct LayoutSettingsForm: Equatable, Sendable {
    public enum WidthKind: String, CaseIterable, Sendable {
        case fraction, points
    }

    public var gaps: Double
    public var padding: Double
    /// True leaves `fullscreen-gap` unset so fullscreen follows `gaps`.
    public var fullscreenGapFollowsGaps: Bool
    public var fullscreenGap: Double
    public var widthKind: WidthKind
    public var widthValue: Double
    public var presetsText: String
    /// NC-08: `preset-window-heights`, the same comma-separated text.
    public var presetHeightsText: String
    public var centerFocusedColumn: CenterFocusedColumnMode
    public var maximizeSingleWindow: Bool

    public init(config: LayoutSectionConfig) {
        gaps = Double(config.gaps)
        padding = Double(config.padding)
        fullscreenGapFollowsGaps = config.fullscreenGap == nil
        fullscreenGap = Double(config.resolvedFullscreenGap)
        if let points = config.defaultColumnWidthPoints {
            widthKind = .points
            widthValue = Double(points)
        } else {
            widthKind = .fraction
            widthValue = Double(config.defaultColumnWidthFraction ?? 0.5)
        }
        presetsText = Self.text(config.presetColumnWidths)
        presetHeightsText = Self.text(config.presetWindowHeights)
        centerFocusedColumn = config.centerFocusedColumn
        maximizeSingleWindow = config.maximizeSingleWindow
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : "\(value)"
    }

    private static func text(_ presets: [ColumnWidthSpec]) -> String {
        presets.compactMap { spec -> String? in
            switch spec {
            case .proportion(let value), .points(let value):
                return text(Double(value))
            case .standard:
                return nil
            }
        }.joined(separator: ", ")
    }

    public var problems: [String] {
        var found: [String] = []
        if !(gaps >= 0 && gaps.isFinite) { found.append("Gaps must be zero or more.") }
        if !(padding >= 0 && padding.isFinite) { found.append("Padding must be zero or more.") }
        let gapRange = LayoutSectionConfig.fullscreenGapRange
        if !fullscreenGapFollowsGaps,
           !(fullscreenGap.isFinite && fullscreenGap >= Double(gapRange.lowerBound) && fullscreenGap <= Double(gapRange.upperBound))
        {
            found.append("Fullscreen gap must be \(gapRange.lowerBound) to \(gapRange.upperBound) points.")
        }
        switch widthKind {
        case .fraction:
            if !(widthValue > 0 && widthValue <= 1) {
                found.append("Default width as a fraction must be above 0 and at most 1.")
            }
        case .points:
            if !(widthValue > 1 && widthValue.isFinite) {
                found.append("Default width in points must be above 1.")
            }
        }
        if parsePresetList(presetsText) == nil {
            found.append("Preset widths must be a comma-separated list of positive numbers.")
        }
        if parsePresetList(presetHeightsText) == nil {
            found.append("Preset heights must be a comma-separated list of positive numbers.")
        }
        return found
    }

    public var edits: [ConfigEdit] {
        [
            .set(table: "layout", key: "gaps", value: .number(gaps)),
            .set(table: "layout", key: "padding", value: .number(padding)),
            fullscreenGapFollowsGaps
                ? .remove(table: "layout", key: "fullscreen-gap")
                : .set(table: "layout", key: "fullscreen-gap", value: .number(fullscreenGap)),
            .set(table: "layout", key: "default-column-width", value: .number(widthValue)),
            .set(table: "layout", key: "center-focused-column", value: .string(centerFocusedColumn.rawValue)),
            .set(table: "layout", key: "maximize-single-window", value: .bool(maximizeSingleWindow)),
            .set(
                table: "layout", key: "preset-column-widths",
                value: .numbers(parsePresetList(presetsText) ?? [])
            ),
            .set(
                table: "layout", key: "preset-window-heights",
                value: .numbers(parsePresetList(presetHeightsText) ?? [])
            ),
        ]
    }
}

public func animationEdits(
    enabled: Bool, durationMilliseconds: Int,
    curve: MotionCurveKind? = nil, springDampingRatio: Double? = nil, springStiffness: Double? = nil,
    resize: ResizeMode? = nil, renderer: RendererKind? = nil,
    focusedGrow: FocusedGrowMode? = nil, nativeZoom: Bool? = nil
) -> [ConfigEdit] {
    var edits: [ConfigEdit] = [
        .set(table: "animations", key: "enabled", value: .bool(enabled)),
        .set(table: "animations", key: "duration-ms", value: .int(durationMilliseconds)),
    ]
    if let curve {
        edits.append(.set(table: "animations", key: "curve", value: .string(curve.rawValue)))
    }
    if let springDampingRatio {
        edits.append(.set(table: "animations", key: "spring-damping-ratio", value: .number(springDampingRatio)))
    }
    if let springStiffness {
        edits.append(.set(table: "animations", key: "spring-stiffness", value: .number(springStiffness)))
    }
    if let resize {
        edits.append(.set(table: "animations", key: "resize", value: .string(resize.rawValue)))
    }
    if let renderer {
        edits.append(.set(table: "animations", key: "renderer", value: .string(renderer.rawValue)))
    }
    if let focusedGrow {
        edits.append(.set(table: "animations", key: "focused-grow", value: .string(focusedGrow.rawValue)))
    }
    if let nativeZoom {
        edits.append(.set(table: "animations", key: "native-zoom", value: .bool(nativeZoom)))
    }
    return edits
}

/// NA-04: one `[animations.<name>]` table: every key the override sets is
/// written, every other one removed (inherits). `offset` and `ghost` are
/// written by the caller for their own kinds.
public func animationOverrideEdits(_ kind: AnimationKind, override: AnimationOverride) -> [ConfigEdit] {
    let table = kind.tableName
    func edit(_ key: String, _ value: ConfigEditValue?) -> ConfigEdit {
        value.map { .set(table: table, key: key, value: $0) } ?? .remove(table: table, key: key)
    }
    return [
        edit("enabled", override.enabled.map { .bool($0) }),
        edit("curve", override.curve.map { .string($0.rawValue) }),
        edit("spring-damping-ratio", override.springDampingRatio.map { .number($0) }),
        edit("spring-stiffness", override.springStiffness.map { .number($0) }),
        edit("duration-ms", override.durationMilliseconds.map { .int($0) }),
    ]
}

public func focusRingEdits(
    enabled: Bool, width: Int, colorHex: String, hideWhenMaximized: Bool = true
) -> [ConfigEdit] {
    [
        .set(table: "focus-ring", key: "enabled", value: .bool(enabled)),
        .set(table: "focus-ring", key: "width", value: .int(width)),
        .set(table: "focus-ring", key: "hide-when-maximized", value: .bool(hideWhenMaximized)),
        .set(table: "focus-ring", key: "active-color", value: .string(colorHex)),
    ]
}

public struct FocusRingSettingsForm: Equatable, Sendable {
    public var enabled: Bool
    public var width: Double
    public var colorText: String
    public var hideWhenMaximized: Bool

    public init(config: FocusRingSectionConfig, theme: GioTheme? = nil) {
        enabled = config.enabled
        hideWhenMaximized = config.hideWhenMaximized
        width = Double(config.width)
        colorText = config.resolvedColor(theme: theme).hex
    }

    public var problems: [String] {
        var found: [String] = []
        let range = FocusRingSectionConfig.widthRange
        if !(width.isFinite && width >= Double(range.lowerBound) && width <= Double(range.upperBound)) {
            found.append("Ring width must be \(range.lowerBound) to \(range.upperBound) points.")
        }
        if ThemeColor(hex: colorText) == nil {
            found.append("Ring color must be a hex color like #7fc8ff.")
        }
        return found
    }

    public var edits: [ConfigEdit] {
        let color = ThemeColor(hex: colorText)?.lowercaseHex ?? colorText
        return focusRingEdits(
            enabled: enabled, width: Int(width.rounded()), colorHex: color, hideWhenMaximized: hideWhenMaximized
        )
    }

    /// The parsed color, nil while the text is not a valid hex color.
    public var color: ThemeColor? {
        ThemeColor(hex: colorText)
    }

    /// Picker and swatch entry point: keeps the text field in sync.
    public mutating func setColor(_ color: ThemeColor) {
        colorText = color.lowercaseHex
    }
}

/// NF-06 `[focus]` edits.
public func focusEdits(indicator: FocusIndicatorKind, dimStrength: Double) -> [ConfigEdit] {
    [
        .set(table: "focus", key: "indicator", value: .string(indicator.rawValue)),
        .set(table: "focus", key: "dim-strength", value: .number(dimStrength)),
    ]
}

public struct FocusSettingsForm: Equatable, Sendable {
    public var indicator: FocusIndicatorKind
    public var dimStrength: Double

    public init(config: FocusSectionConfig) {
        indicator = config.indicator
        dimStrength = config.dimStrength
    }

    public var problems: [String] {
        let range = FocusSectionConfig.dimStrengthRange
        guard dimStrength.isFinite, range.contains(dimStrength) else {
            return ["Dim strength must be \(range.lowerBound) to \(range.upperBound)."]
        }
        return []
    }

    public var edits: [ConfigEdit] {
        // Two decimals keep the slider's value readable in config.toml.
        focusEdits(indicator: indicator, dimStrength: (dimStrength * 100).rounded() / 100)
    }
}

public func behaviorEdits(focusFollowsMouse: Bool, mouseFollowsFocus: Bool) -> [ConfigEdit] {
    [
        .set(table: "behavior", key: "focus-follows-mouse", value: .bool(focusFollowsMouse)),
        .set(table: "behavior", key: "mouse-follows-focus", value: .bool(mouseFollowsFocus)),
    ]
}

/// DA-07: `[logging] level`, the minimum severity written to `gio.log`.
public func logLevelEdits(_ level: LogLevel) -> [ConfigEdit] {
    [.set(table: "logging", key: "level", value: .string(level.name))]
}

/// WR-06: how the Rules form sets a rule's `default-column-width`.
public enum RuleWidthChoice: String, Equatable, Sendable, CaseIterable {
    /// No key: the `[layout]` default width.
    case layoutDefault
    case fraction
    case points
}

/// Editable window rule. `mode`/`workspace` nil mean "no opinion"; an
/// empty `title` means no title matcher. Validation is the parser's
/// (`TitlePattern`, `ruleColumnWidth`, `isValidRuleWidthLimit`).
public struct RuleForm: Equatable, Sendable {
    public var app: String
    public var mode: WindowMode?
    public var workspace: Int?
    public var bundleID: String?
    public var openOnWorkspace: String?
    public var follow: WorkspaceFollowPolicy
    /// WR-01: the title regular expression, verbatim.
    public var title: String
    public var widthChoice: RuleWidthChoice
    /// The fraction (≤ 1) or points of `widthChoice`.
    public var widthValue: Double
    public var openMaximized: Bool
    public var openOnDisplay: Int?
    public var openFocused: Bool
    public var minWidth: Double?
    public var maxWidth: Double?

    public init(
        app: String = "", mode: WindowMode? = nil, workspace: Int? = nil,
        bundleID: String? = nil, openOnWorkspace: String? = nil, follow: WorkspaceFollowPolicy = .whenActive,
        title: String = "", widthChoice: RuleWidthChoice = .layoutDefault, widthValue: Double = 0.5,
        openMaximized: Bool = false, openOnDisplay: Int? = nil, openFocused: Bool = true,
        minWidth: Double? = nil, maxWidth: Double? = nil
    ) {
        self.app = app
        self.mode = mode
        self.workspace = workspace
        self.bundleID = bundleID
        self.openOnWorkspace = openOnWorkspace
        self.follow = follow
        self.title = title
        self.widthChoice = widthChoice
        self.widthValue = widthValue
        self.openMaximized = openMaximized
        self.openOnDisplay = openOnDisplay
        self.openFocused = openFocused
        self.minWidth = minWidth
        self.maxWidth = maxWidth
    }

    public init(rule: WindowRule) {
        let widthChoice: RuleWidthChoice
        let widthValue: Double
        switch rule.columnWidth {
        case .proportion(let value)?:
            widthChoice = .fraction
            widthValue = Double(value)
        case .points(let value)?:
            widthChoice = .points
            widthValue = Double(value)
        case .standard?, nil:
            widthChoice = .layoutDefault
            widthValue = 0.5
        }
        self.init(
            app: rule.app, mode: rule.mode, workspace: rule.workspace,
            bundleID: rule.bundleID, openOnWorkspace: rule.openOnWorkspace, follow: rule.follow,
            title: rule.title?.pattern ?? "", widthChoice: widthChoice, widthValue: widthValue,
            openMaximized: rule.openMaximized, openOnDisplay: rule.openOnDisplay, openFocused: rule.openFocused,
            minWidth: rule.minWidth.map { Double($0) }, maxWidth: rule.maxWidth.map { Double($0) }
        )
    }

    /// Switch the width unit, keeping `widthValue` meaningful for it (the
    /// fraction and points sliders have different ranges).
    public mutating func adoptWidthChoice(_ choice: RuleWidthChoice) {
        widthChoice = choice
        switch choice {
        case .fraction where !(widthValue > 0 && widthValue <= 1):
            widthValue = 0.5
        case .points where !isValidRuleWidthLimit(widthValue):
            widthValue = 800
        case .layoutDefault, .fraction, .points:
            break
        }
    }

    public var problems: [String] {
        var found: [String] = []
        let trimmed = app.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, bundleID?.isEmpty ?? true, title.isEmpty {
            found.append("App name or title pattern is required.")
        }
        if trimmed.contains("\"") { found.append("App name cannot contain a double quote.") }
        if title.contains("\"") {
            found.append("Title pattern cannot contain a double quote.")
        } else if !title.isEmpty, TitlePattern(title) == nil {
            found.append("Title pattern is not a valid regular expression.")
        }
        if let workspace, !WorkspaceManager.range.contains(workspace) {
            found.append("Workspace must be 1 to 9.")
        }
        switch widthChoice {
        case .layoutDefault:
            break
        case .fraction where !(widthValue.isFinite && widthValue > 0 && widthValue <= 1):
            found.append("Width fraction must be more than 0 and at most 1.")
        case .points where !isValidRuleWidthLimit(widthValue):
            found.append("Width in points must be more than 1.")
        case .fraction, .points:
            break
        }
        if let openOnDisplay, openOnDisplay < 1 { found.append("Display must be 1 or more.") }
        if let minWidth, !isValidRuleWidthLimit(minWidth) {
            found.append("Minimum width must be more than 1 point.")
        }
        if let maxWidth, !isValidRuleWidthLimit(maxWidth) {
            found.append("Maximum width must be more than 1 point.")
        }
        if let minWidth, let maxWidth, isValidRuleWidthLimit(minWidth), isValidRuleWidthLimit(maxWidth),
           minWidth > maxWidth
        {
            found.append("Minimum width cannot be above the maximum width.")
        }
        return found
    }

    public var rule: WindowRule {
        WindowRule(
            app: app.trimmingCharacters(in: .whitespaces), bundleID: bundleID, title: TitlePattern(title),
            mode: mode, workspace: workspace, openOnWorkspace: openOnWorkspace, follow: follow,
            columnWidth: widthChoice == .layoutDefault ? nil : ruleColumnWidth(widthValue),
            openMaximized: openMaximized, openOnDisplay: openOnDisplay, openFocused: openFocused,
            minWidth: minWidth.map { CGFloat($0) }, maxWidth: maxWidth.map { CGFloat($0) }
        )
    }
}
