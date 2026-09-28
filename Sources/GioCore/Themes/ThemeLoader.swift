import CoreGraphics
import Foundation

/// Load `~/.config/gio/themes/<name>/theme.toml` over the shared subset
/// parser: unknown keys warn, invalid values fail the file (never a half
/// theme). Lookup order: user directory (case-insensitive) → built-ins →
/// default theme plus an error message.
public func loadTheme(named name: String, from directory: String? = nil) -> (
    theme: GioTheme, messages: [String]
) {
    let root = directory
        ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/themes")
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: root),
       let match = entries.first(where: { $0.lowercased() == name.lowercased() })
    {
        let file = ((root as NSString).appendingPathComponent(match) as NSString)
            .appendingPathComponent("theme.toml")
        if let text = try? String(contentsOfFile: file, encoding: .utf8) {
            switch parseThemeTOML(text, name: match) {
            case .success(let theme, let warnings):
                return (theme, warnings)
            case .failure(let errors):
                return (defaultTheme(), errors.messages)
            }
        }
    }
    if let builtin = builtinThemes().first(where: { $0.name.lowercased() == name.lowercased() }) {
        return (builtin, [])
    }
    return (defaultTheme(), ["unknown theme '\(name)', using default"])
}

func parseThemeTOML(_ text: String, name: String) -> Result<(GioTheme, [String]), ConfigErrors> {
    var theme = GioTheme(name: name)
    var warnings: [String] = []
    var errors: [String] = []
    var section = ""
    var ignoredSection = false
    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (offset, raw) in rawLines.enumerated() {
        let line = offset + 1
        let stripped = stripComment(raw).trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty {
            continue
        }
        if stripped.hasPrefix("[") {
            guard stripped.hasSuffix("]"), !stripped.hasPrefix("[["), !stripped.hasSuffix("]]") else {
                errors.append("line \(line): malformed table header")
                continue
            }
            section = String(stripped.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if !["theme", "colors", "layout", "bar", "launcher", "wallpaper", "typography"].contains(section) {
                warnings.append("line \(line): unknown table [\(section)], ignored")
                section = ""
                ignoredSection = true
            } else {
                ignoredSection = false
            }
            continue
        }
        guard let equals = stripped.firstIndex(of: "=") else {
            errors.append("line \(line): expected key = value")
            continue
        }
        let key = String(stripped[..<equals]).trimmingCharacters(in: .whitespaces).trimmingQuotes()
        let rawValue = String(stripped[stripped.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard let value = parseConfigValue(rawValue) else {
            errors.append("line \(line): cannot parse value for '\(key)'")
            continue
        }
        applyThemeKey(key, value: value, section: section, ignored: ignoredSection, line: line, warnings: &warnings, errors: &errors, theme: &theme)
    }
    if errors.isEmpty {
        return .success((theme, warnings))
    }
    return .failure(ConfigErrors(messages: errors))
}

func applyThemeKey(
    _ key: String, value: ConfigValue, section: String, ignored: Bool, line: Int,
    warnings: inout [String], errors: inout [String], theme: inout GioTheme
) {
    guard !ignored else {
        return
    }
    func color(_ assign: (ThemeColor) -> Void) {
        guard case .string(let hex) = value, let color = ThemeColor(hex: hex) else {
            errors.append("line \(line): '\(key)' expects a #RGB or #RRGGBB color")
            return
        }
        assign(color)
    }
    func number(_ assign: (CGFloat) -> Void) {
        guard let number = value.number, number >= 0, number.isFinite else {
            errors.append("line \(line): '\(key)' expects a non-negative number")
            return
        }
        assign(CGFloat(number))
    }
    switch (section, key) {
    case ("theme", "name"):
        if case .string(let name) = value, !name.isEmpty {
            theme.name = name
        } else {
            errors.append("line \(line): theme.name expects a non-empty string")
        }
    case ("colors", "background"): color { theme.background = $0 }
    case ("colors", "foreground"): color { theme.foreground = $0 }
    case ("colors", "accent"): color { theme.accent = $0 }
    case ("colors", "border-active"): color { theme.borderActive = $0 }
    case ("colors", "border-inactive"): color { theme.borderInactive = $0 }
    case ("layout", "gaps"): number { theme.gaps = $0 }
    case ("layout", "border-width"): number { theme.borderWidth = $0 }
    case ("bar", "background"): color { theme.barBackground = $0 }
    case ("bar", "text-size"): number { theme.barTextSize = Double($0) }
    case ("launcher", "background"): color { theme.launcherBackground = $0 }
    case ("launcher", "text-size"): number { theme.launcherTextSize = Double($0) }
    case ("wallpaper", "path"):
        guard case .string(let path) = value, !path.isEmpty else {
            errors.append("line \(line): wallpaper.path expects a non-empty string")
            return
        }
        theme.wallpaper = path
    case ("typography", "family"):
        guard case .string(let family) = value, !family.isEmpty else {
            errors.append("line \(line): typography.family expects a non-empty string")
            return
        }
        theme.fontFamily = family
    case ("theme", _), ("colors", _), ("layout", _), ("bar", _),
        ("launcher", _), ("wallpaper", _), ("typography", _):
        warnings.append("line \(line): unknown \(section) key '\(key)', ignored")
    default:
        errors.append("line \(line): key '\(key)' outside any table")
    }
}
