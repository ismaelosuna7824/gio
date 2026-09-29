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
    case focusRing
    case keybindings
    case windowRules
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

    func closeRule(line: Int) {
        guard ruleHasContent else {
            return
        }
        buildRule(ruleDraft, line: line, errors: &errors, config: &config)
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
            case "keybindings": section = .keybindings
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
        case .focusRing:
            applyFocusRingKey(key, value: value, line: line, errors: &errors, warnings: &warnings, config: &config)
        case .keybindings:
            applyBindingKey(key, value: value, line: line, errors: &errors, config: &config)
        case .windowRules:
            ruleDraft[key] = value
            ruleHasContent = true
        case .ignored:
            break
        }
    }
    closeRule(line: rawLines.count + 1)
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
    } else {
        warnings.append("line \(line): unknown animations key '\(key)', ignored")
    }
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
    guard let action = parseActionName(name) else {
        errors.append(
            "line \(line): unknown action '\(name)' (valid: \(validActionNames().joined(separator: ", ")))"
        )
        return
    }
    config.keybindings.append((combo, action))
}

func buildRule(
    _ draft: [String: ConfigValue], line: Int,
    errors: inout [String], config: inout GioConfig
) {
    guard case .string(let app) = draft["app"], !app.isEmpty else {
        errors.append("line \(line): window-rules needs a non-empty app string")
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
    config.rules.append(WindowRule(app: app, mode: mode, workspace: workspace))
}

/// Action vocabulary for config values: plan verbs plus `workspace N` and
/// `move-to-workspace N` (mirroring the plan's `"workspace 1"` spelling).
public func parseActionName(_ text: String) -> HotkeyAction? {
    switch text {
    case "focus-left": return .focusLeft
    case "focus-right": return .focusRight
    case "focus-up": return .focusUp
    case "focus-down": return .focusDown
    case "move-left": return .moveLeft
    case "move-right": return .moveRight
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
    return nil
}

public func validActionNames() -> [String] {
    [
        "focus-left", "focus-right", "focus-up", "focus-down",
        "move-left", "move-right", "move-up", "move-down",
        "workspace N", "move-to-workspace N",
        "toggle-floating", "fullscreen",
        "switch-preset-column-width", "set-column-width-minus", "set-column-width-plus",
        "maximize-column", "center-column",
        "consume-or-expel-window-left", "consume-or-expel-window-right",
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
