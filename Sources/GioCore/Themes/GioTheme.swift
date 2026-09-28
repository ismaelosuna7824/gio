import CoreGraphics
import Foundation

/// Plan §27 theme: selective overrides — every field is optional except the
/// name, so a theme states only what it owns and the running config stands
/// for the rest. Colors are sRGB hex; sizes are points.
public struct ThemeColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#RGB` or `#RRGGBB`, case-insensitive, optional leading `#`.
    public init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        if cleaned.count == 3 {
            cleaned = cleaned.map { "\($0)\($0)" }.joined()
        }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return nil
        }
        self.red = Double((value >> 16) & 0xFF) / 255
        self.green = Double((value >> 8) & 0xFF) / 255
        self.blue = Double(value & 0xFF) / 255
    }

    public var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

public struct GioTheme: Equatable, Sendable {
    public var name: String
    public var background: ThemeColor?
    public var foreground: ThemeColor?
    public var accent: ThemeColor?
    public var borderActive: ThemeColor?
    public var borderInactive: ThemeColor?
    public var gaps: CGFloat?
    public var borderWidth: CGFloat?
    public var barBackground: ThemeColor?
    public var barTextSize: Double?
    public var launcherBackground: ThemeColor?
    public var launcherTextSize: Double?
    public var wallpaper: String?
    public var fontFamily: String?

    public init(name: String) {
        self.name = name
    }

    /// Theme gaps win when set, else the running config stands.
    public func resolveGaps(fallback: CGFloat) -> CGFloat {
        gaps ?? fallback
    }

    /// Theme border width, defaulting to 2pt when unset.
    public func resolveBorderWidth() -> CGFloat {
        borderWidth ?? 2
    }

    public func applying(to layout: LayoutConfig) -> LayoutConfig {
        var next = layout
        if let gaps {
            next.gap = gaps
            next.padding = gaps
        }
        return next
    }
}

/// The four plan palettes, baked in so a fresh install looks right with no
/// files. User directories override by name (case-insensitive).
public func builtinThemes() -> [GioTheme] {
    func theme(
        _ name: String, _ bg: String, _ fg: String, _ accent: String,
        _ active: String, _ inactive: String, gaps: CGFloat
    ) -> GioTheme {
        var theme = GioTheme(name: name)
        theme.background = ThemeColor(hex: bg)
        theme.foreground = ThemeColor(hex: fg)
        theme.accent = ThemeColor(hex: accent)
        theme.borderActive = ThemeColor(hex: active)
        theme.borderInactive = ThemeColor(hex: inactive)
        theme.gaps = gaps
        theme.fontFamily = "SF Mono"
        return theme
    }
    return [
        theme("tokyo-night", "#1A1B26", "#C0CAF5", "#7AA2F7", "#7AA2F7", "#3B4261", gaps: 8),
        theme("catppuccin", "#1E1E2E", "#CDD6F4", "#CBA6F7", "#CBA6F7", "#45475A", gaps: 10),
        theme("nord", "#2E3440", "#D8DEE9", "#88C0D0", "#88C0D0", "#4C566A", gaps: 8),
        theme("gruvbox", "#282828", "#EBDBB2", "#FABD2F", "#FABD2F", "#504945", gaps: 6),
    ]
}

public func defaultTheme() -> GioTheme {
    builtinThemes()[0]
}
