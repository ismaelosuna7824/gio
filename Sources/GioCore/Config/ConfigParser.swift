import CoreGraphics
import Foundation

/// Parse errors, collected — every message names its line.
public struct ConfigErrors: Error, Equatable {
    public var messages: [String]

    public init(messages: [String]) {
        self.messages = messages
    }
}

enum ConfigValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([ConfigValue])

    var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string, .bool, .array: return nil
        }
    }
}

private enum ConfigSection: Equatable {
    case none
    case layout
    case behavior
    case animations
    case animationKind(AnimationKind)
    case focusRing
    case focus
    case logging
    case gestures
    case keybindings
    case windowRules
    case workspaceEntry
    case dwindle
    case ignored(String)
}

/// Subset TOML: `[table]` and `[[window-rules]]` headers, `key = value`
/// with double-quoted strings, ints, doubles, bare bools, and `#` comments
/// (outside quotes). Anything else is rejected with a line-numbered error —
/// the parser never guesses. Unknown tables and unknown keys in known
/// tables are warnings (forward compatibility), never errors.
public func parseGioConfig(_ text: String) -> Result<(GioConfig, [String]), ConfigErrors> {
    var config = defaultGioConfig()
    var warnings: [String] = []
    var errors: [String] = []
    var section: ConfigSection = .none
    var ruleDraft: [String: ConfigValue] = [:]
    var ruleHasContent = false
    var ruleLines: [Int] = []
    var workspaceDraft: [String: ConfigValue] = [:]
    var workspaceOpen = false
    var workspaceLine = 0

    func closeRule(line: Int) {
        if workspaceOpen {
            buildWorkspace(workspaceDraft, line: workspaceLine, errors: &errors, warnings: &warnings, config: &config)
            workspaceDraft = [:]
            workspaceOpen = false
        }
        guard ruleHasContent else {
            return
        }
        let before = config.rules.count
        buildRule(ruleDraft, line: line, errors: &errors, warnings: &warnings, config: &config)
        if config.rules.count > before {
            ruleLines.append(line)
        }
        ruleDraft = [:]
        ruleHasContent = false
    }

    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (offset, raw) in rawLines.enumerated() {
        let line = offset + 1
        let stripped = stripComment(raw).trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty {
            continue
        }
        if stripped.hasPrefix("[[") {
            guard stripped.hasSuffix("]]") else {
                errors.append("line \(line): malformed table header")
                continue
            }
            closeRule(line: line)
            let name = String(stripped.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            if name == "window-rules" {
                section = .windowRules
            } else if name == "workspace" {
                section = .workspaceEntry
                workspaceOpen = true
                workspaceLine = line
            } else {
                warnings.append("line \(line): unknown table [[\(name)]], ignored")
                section = .ignored(name)
            }
            continue
        }
        if stripped.hasPrefix("[") {
            guard stripped.hasSuffix("]") else {
                errors.append("line \(line): malformed table header")
                continue
            }
            closeRule(line: line)
            switch String(stripped.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) {
            case "layout": section = .layout
            case "behavior": section = .behavior
            case "animations": section = .animations
            case "focus-ring": section = .focusRing
            case "focus": section = .focus
            case "logging": section = .logging
            case "gestures": section = .gestures
            case "keybindings": section = .keybindings
            case "dwindle": section = .dwindle
            case let name where name.hasPrefix("animations."):
                // NA-04: `[animations.<niri name>]`.
                if let kind = AnimationKind(rawValue: String(name.dropFirst("animations.".count))) {
                    section = .animationKind(kind)
                } else {
                    warnings.append("line \(line): unknown table [\(name)], ignored")
                    section = .ignored(name)
                }
            case let name:
                warnings.append("line \(line): unknown table [\(name)], ignored")
                section = .ignored(name)
            }
            continue
        }
        guard let equals = stripped.firstIndex(of: "=") else {
            errors.append("line \(line): expected key = value")
            continue
        }
        let key = String(stripped[..<equals]).trimmingCharacters(in: .whitespaces)
            .trimmingQuotes()
        let rawValue = String(stripped[stripped.index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            errors.append("line \(line): empty key")
            continue
        }
        guard let value = parseConfigValue(rawValue) else {
            errors.append("line \(line): cannot parse value for '\(key)'")
            continue
        }
        switch section {
        case .none:
            errors.append("line \(line): key '\(key)' outside any table")
        case .layout:
            applyLayoutKey(key, value: value, line: line, errors: &errors, warnings: &warnings, config: &config)
        case .behavior:
            applyBehaviorKey(key, value: value, line: line, errors: &errors, warnings: &warnings, config: &config)
        case .animations:
            applyAnimationsKey(key, value: value, line: line, errors: &errors, warnings: &warnings, config: &config)
        case .animationKind(let kind):
            applyAnimationKindKey(
                kind, key: key, value: value, line: line, errors: &errors, warnings: &warnings, config: &config
            )
        case .focusRing:
            applyFocusRingKey(key, value: value, line: line, errors: &errors, warnings: &warnings, config: &config)
        case .focus:
            applyFocusKey(key, value: value, line: line, errors: &errors, warnings: &warnings, config: &config)
        case .logging:
            applyLoggingKey(key, value: value, line: line, errors: &errors, warnings: &warnings, config: &config)
        case .dwindle:
            applyDwindleKey(key, value: value, line: line, warnings: &warnings, config: &config)
        case .gestures:
            applyGesturesKey(key, value: value, line: line, warnings: &warnings, config: &config)
        case .keybindings:
            applyBindingKey(key, value: value, line: line, errors: &errors, config: &config)
        case .windowRules:
            ruleDraft[key] = value
            ruleHasContent = true
        case .workspaceEntry:
            if workspaceKeys.contains(key) {
                workspaceDraft[key] = value
            } else {
                warnings.append("line \(line): unknown workspace key '\(key)', ignored")
            }
        case .ignored:
            break
        }
    }
    closeRule(line: rawLines.count + 1)
    validateGestures(&config, warnings: &warnings)
    // NW-01: a rule naming no [[workspace]] keeps its other opinions.
    let names = Set(config.workspaces.map(\.name))
    for index in config.rules.indices {
        if let target = config.rules[index].openOnWorkspace, !names.contains(target) {
            warnings.append(
                "line \(ruleLines[index]): window-rules open-on-workspace '\(target)' names no [[workspace]], ignored"
            )
            config.rules[index].openOnWorkspace = nil
        } else if config.rules[index].openOnWorkspace != nil, let number = config.rules[index].workspace {
            warnings.append(
                "line \(ruleLines[index]): window-rules open-on-workspace wins over workspace = \(number)"
            )
            config.rules[index].workspace = nil
        }
    }
    if errors.isEmpty {
        return .success((config, warnings))
    }
    return .failure(ConfigErrors(messages: errors))
}

func stripComment(_ line: String) -> String {
    var inside = false
    var result = ""
    for char in line {
        if char == "\"" {
            inside.toggle()
        }
        if char == "#" && !inside {
            break
        }
        result.append(char)
    }
    return result
}

func parseConfigValue(_ raw: String) -> ConfigValue? {
    if raw.hasPrefix("\"") {
        guard raw.count >= 2, raw.hasSuffix("\"") else {
            return nil
        }
        return .string(String(raw.dropFirst().dropLast()))
    }
    if raw.hasPrefix("[") {
        // Flat list of numbers, e.g. `[0.33, 0.5, 800]`; a trailing comma is
        // tolerated, nested lists are not.
        guard raw.hasSuffix("]") else {
            return nil
        }
        let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if inner.isEmpty {
            return .array([])
        }
        var items: [ConfigValue] = []
        var parts = inner.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.last == "" {
            parts.removeLast()
        }
        for part in parts {
            guard !part.hasPrefix("["), let item = parseConfigValue(part) else {
                return nil
            }
            items.append(item)
        }
        return .array(items)
    }
    switch raw {
    case "true": return .bool(true)
    case "false": return .bool(false)
    default: break
    }
    if let int = Int(raw) {
        return .int(int)
    }
    if let double = Double(raw) {
        return .double(double)
    }
    return nil
}

func applyLayoutKey(
    _ key: String, value: ConfigValue, line: Int,
    errors: inout [String], warnings: inout [String], config: inout GioConfig
) {
    switch key {
    case "gaps", "padding":
        guard let number = value.number, number >= 0, number.isFinite else {
            errors.append("line \(line): layout.\(key) expects a non-negative number")
            return
        }
        if key == "gaps" {
            config.layout.gaps = CGFloat(number)
        } else {
            config.layout.padding = CGFloat(number)
        }
    case "fullscreen-gap":
        let range = LayoutSectionConfig.fullscreenGapRange
        guard let number = value.number, number.isFinite,
              number >= Double(range.lowerBound), number <= Double(range.upperBound)
        else {
            errors.append(
                "line \(line): layout.fullscreen-gap expects a number of points from \(range.lowerBound) to \(range.upperBound)"
            )
            return
        }
        config.layout.fullscreenGap = CGFloat(number)
    case "default-column-width":
        guard let number = value.number, number > 0, number.isFinite else {
            errors.append("line \(line): layout.default-column-width expects a positive number")
            return
        }
        if number <= 1 {
            config.layout.defaultColumnWidthFraction = CGFloat(number)
            config.layout.defaultColumnWidthPoints = nil
        } else {
            config.layout.defaultColumnWidthPoints = CGFloat(number)
            config.layout.defaultColumnWidthFraction = nil
        }
    case "preset-column-widths":
        guard case .array(let items) = value, !items.isEmpty else {
            errors.append(
                "line \(line): layout.preset-column-widths expects a non-empty list of positive numbers"
            )
            return
        }
        var specs: [ColumnWidthSpec] = []
        for item in items {
            guard let number = item.number, number > 0, number.isFinite else {
                errors.append(
                    "line \(line): layout.preset-column-widths expects a non-empty list of positive numbers"
                )
                return
            }
            specs.append(number <= 1 ? .proportion(CGFloat(number)) : .points(CGFloat(number)))
        }
        config.layout.presetColumnWidths = specs
    case "preset-window-heights":
        // NC-08: same list rule as the widths.
        guard case .array(let items) = value, !items.isEmpty else {
            errors.append(
                "line \(line): layout.preset-window-heights expects a non-empty list of positive numbers"
            )
            return
        }
        var specs: [ColumnWidthSpec] = []
        for item in items {
            guard let number = item.number, number > 0, number.isFinite else {
                errors.append(
                    "line \(line): layout.preset-window-heights expects a non-empty list of positive numbers"
                )
                return
            }
            specs.append(number <= 1 ? .proportion(CGFloat(number)) : .points(CGFloat(number)))
        }
        config.layout.presetWindowHeights = specs
    case "center-focused-column":
        // Strings since HD-04; the old boolean keeps working (true = always).
        if case .bool(let enabled) = value {
            config.layout.centerFocusedColumn = CenterFocusedColumnMode(legacy: enabled)
        } else if case .string(let text) = value, let mode = CenterFocusedColumnMode(rawValue: text) {
            config.layout.centerFocusedColumn = mode
        } else {
            errors.append(
                "line \(line): layout.center-focused-column expects \"never\", \"always\" or \"on-overflow\""
            )
        }
    case "new-window-position":
        if case .string(let text) = value, let position = NewWindowPosition(rawValue: text) {
            config.layout.newWindowPosition = position
        } else {
            errors.append(
                "line \(line): layout.new-window-position expects \"end\", \"start\", \"right-of-focused\" or \"left-of-focused\""
            )
        }
    case "maximize-single-window":
        applyBoolKey(key, expected: key, value: value, line: line, table: "layout", errors: &errors) {
            config.layout.maximizeSingleWindow = $0
        }
    case "default-layout":
        // DW-03: an unknown layout warns and keeps the default (the brief's
        // rule for the layout keys; the WM always has a valid layout).
        if case .string(let text) = value, let kind = WorkspaceLayoutKind(rawValue: text) {
            config.layout.defaultLayout = kind
        } else {
            warnings.append("line \(line): layout.default-layout expects \"scrolling\" or \"dwindle\", default kept")
        }
    case "always-center-single-column":
        applyBoolKey(key, expected: key, value: value, line: line, table: "layout", errors: &errors) {
            config.layout.alwaysCenterSingleColumn = $0
        }
    default:
        warnings.append("line \(line): unknown layout key '\(key)', ignored")
    }
}

func applyBoolKey(
    _ key: String, expected: String, value: ConfigValue, line: Int, table: String,
    errors: inout [String], set: (Bool) -> Void
) {
    guard key == expected else {
        return
    }
    guard case .bool(let enabled) = value else {
        errors.append("line \(line): \(table).\(key) expects true or false")
        return
    }
    set(enabled)
}

func applyBehaviorKey(
    _ key: String, value: ConfigValue, line: Int,
    errors: inout [String], warnings: inout [String], config: inout GioConfig
) {
    switch key {
    case "focus-follows-mouse":
        applyBoolKey(key, expected: key, value: value, line: line, table: "behavior", errors: &errors) {
            config.behavior.focusFollowsMouse = $0
        }
    case "mouse-follows-focus":
        applyBoolKey(key, expected: key, value: value, line: line, table: "behavior", errors: &errors) {
            config.behavior.mouseFollowsFocus = $0
        }
    case "move-crosses-monitor-at-edge":
        applyBoolKey(key, expected: key, value: value, line: line, table: "behavior", errors: &errors) {
            config.behavior.moveCrossesMonitorAtEdge = $0
        }
    default:
        warnings.append("line \(line): unknown behavior key '\(key)', ignored")
    }
}

func applyAnimationsKey(
    _ key: String, value: ConfigValue, line: Int,
    errors: inout [String], warnings: inout [String], config: inout GioConfig
) {
    if key == "enabled" {
        applyBoolKey(key, expected: key, value: value, line: line, table: "animations", errors: &errors) {
            config.animations.enabled = $0
        }
    } else if key == "duration-ms" {
        guard let number = value.number, number.isFinite else {
            errors.append("line \(line): animations.duration-ms expects a number of milliseconds")
            return
        }
        let range = AnimationsSectionConfig.durationRange
        let rounded = Int(min(max(number.rounded(), Double(range.lowerBound)), Double(range.upperBound)))
        if Double(rounded) != number.rounded() {
            warnings.append(
                "line \(line): animations.duration-ms clamped to \(rounded) (valid \(range.lowerBound)-\(range.upperBound))"
            )
        }
        config.animations.durationMilliseconds = rounded
    } else if key == "curve" {
        guard case .string(let text) = value else {
            errors.append("line \(line): animations.curve expects \"spring\" or \"ease-out\"")
            return
        }
        if let curve = MotionCurveKind(rawValue: text) {
            config.animations.curve = curve
        } else {
            warnings.append("line \(line): animations.curve '\(text)' is not \"spring\" or \"ease-out\", using the default")
        }
    } else if key == "resize" {
        guard case .string(let text) = value else {
            errors.append("line \(line): animations.resize expects \"adaptive\", \"always\" or \"never\"")
            return
        }
        if let mode = ResizeMode(rawValue: text) {
            config.animations.resize = mode
        } else {
            warnings.append(
                "line \(line): animations.resize '\(text)' is not \"adaptive\", \"always\" or \"never\", using the default"
            )
        }
    } else if key == "focused-grow" {
        guard case .string(let text) = value else {
            errors.append("line \(line): animations.focused-grow expects \"start\" or \"end\"")
            return
        }
        if let mode = FocusedGrowMode(rawValue: text) {
            config.animations.focusedGrow = mode
        } else {
            warnings.append(
                "line \(line): animations.focused-grow '\(text)' is not \"start\" or \"end\", using the default"
            )
        }
    } else if key == "native-zoom" {
        applyBoolKey(key, expected: key, value: value, line: line, table: "animations", errors: &errors) {
            config.animations.nativeZoom = $0
        }
    } else if key == "renderer" {
        guard case .string(let text) = value else {
            errors.append("line \(line): animations.renderer expects \"snapshot\" or \"ax\"")
            return
        }
        if let kind = RendererKind(rawValue: text) {
            config.animations.renderer = kind
        } else {
            warnings.append(
                "line \(line): animations.renderer '\(text)' is not \"snapshot\" or \"ax\", using the default"
            )
        }
    } else if key == "spring-damping-ratio" {
        applySpringNumber(
            key, value: value, line: line, range: SpringParameters.dampingRatioRange,
            errors: &errors, warnings: &warnings
        ) { config.animations.springDampingRatio = $0 }
    } else if key == "spring-stiffness" {
        applySpringNumber(
            key, value: value, line: line, range: SpringParameters.stiffnessRange,
            errors: &errors, warnings: &warnings
        ) { config.animations.springStiffness = $0 }
    } else {
        warnings.append("line \(line): unknown animations key '\(key)', ignored")
    }
}

/// NA-04: one `[animations.<name>]` key. Same keys and validation as the
/// global table (enabled, curve, duration-ms, spring-*), plus `offset` for
/// window-open and `ghost` for window-close.
func applyAnimationKindKey(
    _ kind: AnimationKind, key: String, value: ConfigValue, line: Int,
    errors: inout [String], warnings: inout [String], config: inout GioConfig
) {
    let table = kind.tableName
    var custom = config.animations.overrides[kind] ?? AnimationOverride()
    defer { config.animations.overrides[kind] = custom.isEmpty ? nil : custom }
    switch key {
    case "enabled":
        applyBoolKey(key, expected: key, value: value, line: line, table: table, errors: &errors) {
            custom.enabled = $0
        }
    case "duration-ms":
        guard let number = value.number, number.isFinite else {
            errors.append("line \(line): \(table).duration-ms expects a number of milliseconds")
            return
        }
        let range = AnimationsSectionConfig.durationRange
        let rounded = Int(min(max(number.rounded(), Double(range.lowerBound)), Double(range.upperBound)))
        if Double(rounded) != number.rounded() {
            warnings.append(
                "line \(line): \(table).duration-ms clamped to \(rounded) (valid \(range.lowerBound)-\(range.upperBound))"
            )
        }
        custom.durationMilliseconds = rounded
    case "curve":
        guard case .string(let text) = value else {
            errors.append("line \(line): \(table).curve expects \"spring\" or \"ease-out\"")
            return
        }
        if let curve = MotionCurveKind(rawValue: text) {
            custom.curve = curve
        } else {
            warnings.append("line \(line): \(table).curve '\(text)' is not \"spring\" or \"ease-out\", inheriting")
        }
    case "spring-damping-ratio":
        applySpringNumber(
            key, value: value, line: line, range: SpringParameters.dampingRatioRange, table: table,
            errors: &errors, warnings: &warnings
        ) { custom.springDampingRatio = $0 }
    case "spring-stiffness":
        applySpringNumber(
            key, value: value, line: line, range: SpringParameters.stiffnessRange, table: table,
            errors: &errors, warnings: &warnings
        ) { custom.springStiffness = $0 }
    case "offset" where kind == .windowOpen:
        applySpringNumber(
            key, value: value, line: line, range: AnimationsSectionConfig.openOffsetRange, table: table,
            errors: &errors, warnings: &warnings
        ) { config.animations.openOffset = $0 }
    case "ghost" where kind == .windowClose:
        applyBoolKey(key, expected: key, value: value, line: line, table: table, errors: &errors) {
            config.animations.closeGhost = $0
        }
    default:
        warnings.append("line \(line): unknown \(table) key '\(key)', ignored")
    }
}

/// A number clamped into `range` (a warning when clamped).
private func applySpringNumber(
    _ key: String, value: ConfigValue, line: Int, range: ClosedRange<Double>, table: String = "animations",
    errors: inout [String], warnings: inout [String], set: (Double) -> Void
) {
    guard let number = value.number, number.isFinite else {
        errors.append("line \(line): \(table).\(key) expects a number")
        return
    }
    let clamped = min(max(number, range.lowerBound), range.upperBound)
    if clamped != number {
        warnings.append(
            "line \(line): \(table).\(key) clamped to \(clamped) (valid \(range.lowerBound)-\(range.upperBound))"
        )
    }
    set(clamped)
}

func applyFocusRingKey(
    _ key: String, value: ConfigValue, line: Int,
    errors: inout [String], warnings: inout [String], config: inout GioConfig
) {
    switch key {
    case "enabled":
        applyBoolKey(key, expected: key, value: value, line: line, table: "focus-ring", errors: &errors) {
            config.focusRing.enabled = $0
        }
    case "width":
        guard let number = value.number, number.isFinite else {
            errors.append("line \(line): focus-ring.width expects a number of points")
            return
        }
        let range = FocusRingSectionConfig.widthRange
        let rounded = Int(min(max(number.rounded(), Double(range.lowerBound)), Double(range.upperBound)))
        if Double(rounded) != number.rounded() {
            warnings.append(
                "line \(line): focus-ring.width clamped to \(rounded) (valid \(range.lowerBound)-\(range.upperBound))"
            )
        }
        config.focusRing.width = rounded
    case "hide-when-maximized":
        applyBoolKey(key, expected: key, value: value, line: line, table: "focus-ring", errors: &errors) {
            config.focusRing.hideWhenMaximized = $0
        }
    case "active-color":
        guard case .string(let text) = value, let color = ThemeColor(hex: text) else {
            errors.append("line \(line): focus-ring.active-color expects a hex color like \"#7fc8ff\"")
            return
        }
        config.focusRing.activeColor = color
    default:
        warnings.append("line \(line): unknown focus-ring key '\(key)', ignored")
    }
}

func applyFocusKey(
    _ key: String, value: ConfigValue, line: Int,
    errors: inout [String], warnings: inout [String], config: inout GioConfig
) {
    switch key {
    case "indicator":
        guard case .string(let text) = value, let kind = FocusIndicatorKind(rawValue: text.lowercased()) else {
            errors.append("line \(line): focus.indicator expects \"dim\", \"ring\" or \"none\"")
            return
        }
        config.focus.indicator = kind
    case "dim-strength":
        guard let number = value.number, number.isFinite else {
            errors.append("line \(line): focus.dim-strength expects a number from 0.0 to 0.5")
            return
        }
        let range = FocusSectionConfig.dimStrengthRange
        let clamped = min(max(number, range.lowerBound), range.upperBound)
        if clamped != number {
            warnings.append(
                "line \(line): focus.dim-strength clamped to \(clamped) (valid \(range.lowerBound)-\(range.upperBound))"
            )
        }
        config.focus.dimStrength = clamped
    default:
        warnings.append("line \(line): unknown focus key '\(key)', ignored")
    }
}

func applyLoggingKey(
    _ key: String, value: ConfigValue, line: Int,
    errors: inout [String], warnings: inout [String], config: inout GioConfig
) {
    switch key {
    case "level":
        guard case .string(let text) = value, let level = LogLevel(name: text) else {
            errors.append("line \(line): logging.level expects one of trace, debug, info, warn, error")
            return
        }
        config.logging.level = level
    default:
        warnings.append("line \(line): unknown logging key '\(key)', ignored")
    }
}

func applyBindingKey(
    _ key: String, value: ConfigValue, line: Int,
    errors: inout [String], config: inout GioConfig
) {
    guard case .string(let name) = value else {
        errors.append("line \(line): keybindings values must be quoted action names")
        return
    }
    guard let combo = parseHotkey(key) else {
        if case .unknownKey(let unknown)? = hotkeyFailure(key) {
            errors.append(
                "line \(line): unknown key '\(unknown)' in hotkey '\(key)' (valid: letters, digits, F1-F12, arrows, punctuation names; see the user guide)"
            )
        } else {
            errors.append("line \(line): cannot parse hotkey '\(key)'")
        }
        return
    }
    // DA-07: `"none"` removes whatever the combo did, defaults included.
    // Lines apply in file order, so the last one for a combo wins.
    if name == unbindActionName {
        config.keybindings.removeAll { $0.0 == combo }
        if !config.unboundKeys.contains(combo) {
            config.unboundKeys.append(combo)
        }
        return
    }
    guard let action = parseActionName(name) else {
        errors.append(
            "line \(line): unknown action '\(name)' (valid: \(validActionNames().joined(separator: ", ")), or \"none\" to unbind)"
        )
        return
    }
    config.unboundKeys.removeAll { $0 == combo }
    config.keybindings.append((combo, action))
}

/// DA-07: the `[keybindings]` value that unbinds a combo.
public let unbindActionName = "none"

private let workspaceKeys: Set<String> = ["name", "icon", "color", "display", "layout"]

/// DW-03: one `[dwindle]` key. Every invalid value is a warning that keeps
/// the default, so a dwindle typo never rejects the rest of the file.
func applyDwindleKey(
    _ key: String, value: ConfigValue, line: Int, warnings: inout [String], config: inout GioConfig
) {
    func number(in range: ClosedRange<Double>, describing text: String) -> CGFloat? {
        guard let number = value.number, number.isFinite, range.contains(number) else {
            warnings.append("line \(line): dwindle.\(key) expects a number from \(text), default kept")
            return nil
        }
        return CGFloat(number)
    }
    switch key {
    case "default-split-ratio":
        if let ratio = number(in: DwindleSectionConfig.splitRatioRange, describing: "0.1 to 1.9") {
            config.dwindle.defaultSplitRatio = ratio
        }
    case "split-width-multiplier":
        if let multiplier = number(in: DwindleSectionConfig.splitWidthMultiplierRange, describing: "0.1 to 10") {
            config.dwindle.splitWidthMultiplier = multiplier
        }
    case "smart-split":
        warnings.append(
            "line \(line): dwindle.smart-split is not supported (Gio has no pointer position when a window opens; use dwindle-preselect-*), ignored"
        )
    default:
        warnings.append("line \(line): unknown dwindle key '\(key)', ignored")
    }
}

/// NW-01: one `[[workspace]]` table; `line` is its header.
func buildWorkspace(
    _ draft: [String: ConfigValue], line: Int,
    errors: inout [String], warnings: inout [String], config: inout GioConfig
) {
    guard case .string(let raw) = draft["name"],
          case let name = raw.trimmingCharacters(in: .whitespaces), !name.isEmpty
    else {
        errors.append("line \(line): workspace needs a non-empty name")
        return
    }
    if config.workspaces.contains(where: { $0.name == name }) {
        errors.append("line \(line): duplicate workspace name '\(name)'")
        return
    }
    var definition = WorkspaceDefinition(name: name)
    if let value = draft["icon"] {
        guard case .string(let icon) = value else {
            errors.append("line \(line): workspace icon expects an SF Symbol name string")
            return
        }
        definition.icon = icon.isEmpty ? nil : icon
    }
    if let value = draft["color"] {
        guard case .string(let color) = value, ThemeColor(hex: color) != nil else {
            errors.append("line \(line): workspace color expects a hex color like \"#7fc8ff\"")
            return
        }
        definition.color = color
    }
    if let value = draft["display"] {
        switch value {
        case .string("main"):
            definition.display = .main
        case .int(let number) where number >= 1:
            definition.display = .index(number)
        default:
            errors.append("line \(line): workspace display expects \"main\" or a display number (1, 2, ...)")
            return
        }
    }
    if let value = draft["layout"] {
        // DW-03: a wrong layout warns; the workspace follows the default layout.
        if case .string(let text) = value, let kind = WorkspaceLayoutKind(rawValue: text) {
            definition.layout = kind
        } else {
            warnings.append("line \(line): workspace layout expects \"scrolling\" or \"dwindle\", default layout kept")
        }
    }
    config.workspaces.append(definition)
}

func buildRule(
    _ draft: [String: ConfigValue], line: Int,
    errors: inout [String], warnings: inout [String], config: inout GioConfig
) {
    var app = ""
    if let raw = draft["app"] {
        guard case .string(let text) = raw else {
            errors.append("line \(line): window-rules app must be a string")
            return
        }
        app = text
    }
    var bundleID: String?
    if let raw = draft["bundle-id"] {
        guard case .string(let text) = raw, !text.isEmpty else {
            errors.append("line \(line): window-rules bundle-id must be a non-empty string")
            return
        }
        bundleID = text
    }
    var title: TitlePattern?
    if let raw = draft["title"] {
        guard case .string(let text) = raw, !text.isEmpty else {
            errors.append("line \(line): window-rules title must be a non-empty regular expression string")
            return
        }
        // The pattern is user config, never a window title: safe to quote.
        guard let pattern = TitlePattern(text) else {
            errors.append("line \(line): window-rules title is not a valid regular expression: \(text)")
            return
        }
        title = pattern
    }
    guard !app.isEmpty || bundleID != nil || title != nil else {
        errors.append("line \(line): window-rules needs a non-empty app or bundle-id string, or a title")
        return
    }
    var mode: WindowMode?
    if let raw = draft["mode"] {
        guard case .string(let name) = raw,
              let parsed = WindowMode(rawValue: name)
        else {
            errors.append("line \(line): window-rules mode must be tiled, floating or fullscreen")
            return
        }
        mode = parsed
    }
    var workspace: Int?
    if let raw = draft["workspace"] {
        guard case .int(let number) = raw, WorkspaceManager.range.contains(number) else {
            errors.append("line \(line): window-rules workspace must be 1...9")
            return
        }
        workspace = number
    }
    var openOnWorkspace: String?
    if let raw = draft["open-on-workspace"] {
        guard case .string(let name) = raw, !name.isEmpty else {
            errors.append("line \(line): window-rules open-on-workspace must be a workspace name")
            return
        }
        openOnWorkspace = name
    }
    var follow = WorkspaceFollowPolicy.whenActive
    if let raw = draft["follow"] {
        guard case .string(let text) = raw, let parsed = WorkspaceFollowPolicy(rawValue: text) else {
            errors.append("line \(line): window-rules follow must be \"when-active\", \"always\" or \"never\"")
            return
        }
        follow = parsed
    }
    var columnWidth: ColumnWidthSpec?
    if let raw = draft["default-column-width"] {
        guard let spec = raw.number.flatMap(ruleColumnWidth) else {
            errors.append("line \(line): window-rules default-column-width expects a positive number")
            return
        }
        columnWidth = spec
    }
    var openMaximized = false
    if let raw = draft["open-maximized"] {
        guard case .bool(let flag) = raw else {
            errors.append("line \(line): window-rules open-maximized expects true or false")
            return
        }
        openMaximized = flag
    }
    var openFocused: Bool?
    if let raw = draft["open-focused"] {
        guard case .bool(let flag) = raw else {
            errors.append("line \(line): window-rules open-focused expects true or false")
            return
        }
        openFocused = flag
    }
    var openOnDisplay: Int?
    if let raw = draft["open-on-display"] {
        guard case .int(let number) = raw, number >= 1 else {
            errors.append("line \(line): window-rules open-on-display expects a display number (1, 2, ...)")
            return
        }
        openOnDisplay = number
    }
    var limits: [String: Double] = [:]
    for key in ["min-width", "max-width"] {
        if let raw = draft[key] {
            guard let number = raw.number, isValidRuleWidthLimit(number) else {
                errors.append("line \(line): window-rules \(key) expects points (a number above 1)")
                return
            }
            limits[key] = number
        }
    }
    if let low = limits["min-width"], let high = limits["max-width"], low > high {
        errors.append(
            "line \(line): window-rules min-width (\(renderRuleNumber(low))) is above max-width (\(renderRuleNumber(high)))"
        )
        return
    }
    config.rules.append(WindowRule(
        app: app, bundleID: bundleID, title: title, mode: mode, workspace: workspace,
        openOnWorkspace: openOnWorkspace, follow: follow, columnWidth: columnWidth,
        openMaximized: openMaximized, openOnDisplay: openOnDisplay, openFocused: openFocused,
        minWidth: limits["min-width"].map { CGFloat($0) }, maxWidth: limits["max-width"].map { CGFloat($0) }
    ))
}

/// "900" for whole numbers, "900.5" otherwise (rule error messages).
private func renderRuleNumber(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : "\(value)"
}

/// Action vocabulary for config values: plan verbs plus `workspace N`,
/// `move-to-workspace N` and `move-column-to-workspace N` (mirroring the
/// plan's `"workspace 1"` spelling).
public func parseActionName(_ text: String) -> HotkeyAction? {
    switch text {
    case "focus-left": return .focusLeft
    case "focus-right": return .focusRight
    case "focus-up": return .focusUp
    case "focus-down": return .focusDown
    case "move-column-left": return .moveColumnLeft
    case "move-column-right": return .moveColumnRight
    // `move-left`/`move-right` keep their pre-FI-06 meaning (stack into the
    // neighbouring column); `move-window-*` is the honest name for it.
    case "move-window-left", "move-left": return .moveLeft
    case "move-window-right", "move-right": return .moveRight
    case "move-up": return .moveUp
    case "move-down": return .moveDown
    case "toggle-floating", "toggle-window-floating": return .toggleFloating
    case "fullscreen", "fullscreen-window": return .fullscreen
    case "switch-preset-column-width": return .switchPresetColumnWidth
    case "set-column-width-minus": return .shrinkColumnWidth
    case "set-column-width-plus": return .growColumnWidth
    case "maximize-column": return .maximizeColumn
    case "center-column": return .centerColumn
    case "consume-or-expel-window-left": return .consumeOrExpelLeft
    case "consume-or-expel-window-right": return .consumeOrExpelRight
    case "focus-workspace-down": return .focusWorkspaceDown
    case "focus-workspace-up": return .focusWorkspaceUp
    case "move-window-to-workspace-down": return .moveWindowToWorkspaceDown
    case "move-window-to-workspace-up": return .moveWindowToWorkspaceUp
    case "toggle-overview": return .toggleOverview
    case "focus-monitor-left": return .focusMonitor(.left)
    case "focus-monitor-right": return .focusMonitor(.right)
    case "focus-monitor-up": return .focusMonitor(.up)
    case "focus-monitor-down": return .focusMonitor(.down)
    case "move-column-to-monitor-left": return .moveColumnToMonitor(.left)
    case "move-column-to-monitor-right": return .moveColumnToMonitor(.right)
    case "move-column-to-monitor-up": return .moveColumnToMonitor(.up)
    case "move-column-to-monitor-down": return .moveColumnToMonitor(.down)
    case "move-window-to-monitor-left": return .moveWindowToMonitor(.left)
    case "move-window-to-monitor-right": return .moveWindowToMonitor(.right)
    case "move-window-to-monitor-up": return .moveWindowToMonitor(.up)
    case "move-window-to-monitor-down": return .moveWindowToMonitor(.down)
    case "move-workspace-to-monitor-left": return .moveWorkspaceToMonitor(.left)
    case "move-workspace-to-monitor-right": return .moveWorkspaceToMonitor(.right)
    case "move-workspace-to-monitor-up": return .moveWorkspaceToMonitor(.up)
    case "move-workspace-to-monitor-down": return .moveWorkspaceToMonitor(.down)
    case "switch-preset-window-height": return .switchPresetWindowHeight
    case "set-window-height-minus": return .shrinkWindowHeight
    case "set-window-height-plus": return .growWindowHeight
    case "reset-window-height": return .resetWindowHeight
    case "focus-column-first": return .focusColumnFirst
    case "focus-column-last": return .focusColumnLast
    case "move-column-to-first": return .moveColumnToFirst
    case "move-column-to-last": return .moveColumnToLast
    case "swap-window-left": return .swapWindowLeft
    case "swap-window-right": return .swapWindowRight
    case "move-column-to-workspace-down": return .moveColumnToWorkspaceDown
    case "move-column-to-workspace-up": return .moveColumnToWorkspaceUp
    case "focus-workspace-previous": return .focusWorkspacePrevious
    case "move-workspace-down": return .moveWorkspaceDown
    case "move-workspace-up": return .moveWorkspaceUp
    case "focus-window-or-workspace-down": return .focusWindowOrWorkspaceDown
    case "focus-window-or-workspace-up": return .focusWindowOrWorkspaceUp
    case "switch-preset-column-width-back": return .switchPresetColumnWidthBack
    case "expand-column-to-available-width": return .expandColumnToAvailableWidth
    case "center-visible-columns": return .centerVisibleColumns
    case "move-column-left-or-to-monitor-left": return .moveColumnLeftOrToMonitorLeft
    case "move-column-right-or-to-monitor-right": return .moveColumnRightOrToMonitorRight
    case "focus-column-or-monitor-left": return .focusColumnOrMonitorLeft
    case "focus-column-or-monitor-right": return .focusColumnOrMonitorRight
    case "toggle-workspace-layout": return .toggleWorkspaceLayout
    case "set-workspace-layout-scrolling": return .setWorkspaceLayout(.scrolling)
    case "set-workspace-layout-dwindle": return .setWorkspaceLayout(.dwindle)
    case "dwindle-toggle-split": return .dwindleToggleSplit
    case "dwindle-swap-split": return .dwindleSwapSplit
    case "dwindle-balance": return .dwindleBalance
    case "dwindle-preselect-left": return .dwindlePreselect(.left)
    case "dwindle-preselect-right": return .dwindlePreselect(.right)
    case "dwindle-preselect-up": return .dwindlePreselect(.up)
    case "dwindle-preselect-down": return .dwindlePreselect(.down)
    case "dwindle-preselect-clear": return .dwindlePreselectClear
    default: break
    }
    if text.hasPrefix("workspace ") {
        if let number = Int(text.dropFirst("workspace ".count)) {
            return .workspace(number)
        }
        return nil
    }
    if text.hasPrefix("move-to-workspace ") {
        if let number = Int(text.dropFirst("move-to-workspace ".count)) {
            return .moveToWorkspace(number)
        }
    }
    if text.hasPrefix("move-column-to-workspace ") {
        if let number = Int(text.dropFirst("move-column-to-workspace ".count)) {
            return .moveColumnToWorkspace(number)
        }
    }
    return nil
}

public func validActionNames() -> [String] {
    [
        "focus-left", "focus-right", "focus-up", "focus-down",
        "move-column-left", "move-column-right", "move-window-left", "move-window-right",
        "move-up", "move-down",
        "workspace N", "move-to-workspace N",
        "focus-workspace-down", "focus-workspace-up",
        "move-window-to-workspace-down", "move-window-to-workspace-up", "toggle-overview",
        "toggle-floating", "fullscreen",
        "switch-preset-column-width", "set-column-width-minus", "set-column-width-plus",
        "maximize-column", "center-column",
        "consume-or-expel-window-left", "consume-or-expel-window-right",
        "focus-monitor-left", "focus-monitor-right", "focus-monitor-up", "focus-monitor-down",
        "move-column-to-monitor-left", "move-column-to-monitor-right",
        "move-column-to-monitor-up", "move-column-to-monitor-down",
        "move-window-to-monitor-left", "move-window-to-monitor-right",
        "move-window-to-monitor-up", "move-window-to-monitor-down",
        "move-workspace-to-monitor-left", "move-workspace-to-monitor-right",
        "move-workspace-to-monitor-up", "move-workspace-to-monitor-down",
        "switch-preset-window-height", "set-window-height-minus", "set-window-height-plus",
        "reset-window-height",
        "focus-column-first", "focus-column-last", "move-column-to-first", "move-column-to-last",
        "swap-window-left", "swap-window-right",
        "move-column-to-workspace N", "move-column-to-workspace-down", "move-column-to-workspace-up",
        "focus-workspace-previous", "move-workspace-down", "move-workspace-up",
        "focus-window-or-workspace-down", "focus-window-or-workspace-up",
        "switch-preset-column-width-back", "expand-column-to-available-width", "center-visible-columns",
        "move-column-left-or-to-monitor-left", "move-column-right-or-to-monitor-right",
        "focus-column-or-monitor-left", "focus-column-or-monitor-right",
        "toggle-workspace-layout", "set-workspace-layout-scrolling", "set-workspace-layout-dwindle",
        "dwindle-toggle-split", "dwindle-swap-split", "dwindle-balance",
        "dwindle-preselect-left", "dwindle-preselect-right", "dwindle-preselect-up", "dwindle-preselect-down",
        "dwindle-preselect-clear",
    ]
}

extension String {
    func trimmingQuotes() -> String {
        let trimmed = self.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
