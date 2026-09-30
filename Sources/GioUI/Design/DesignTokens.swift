import AppKit
import GioCore
import SwiftUI

/// DD-01 design tokens. Every Gio surface takes spacing, radii, type and
/// color from here so the app reads as one system in light and dark mode.

/// 4-point spacing scale.
public enum GioSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let l: CGFloat = 20
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

/// Continuous corner radii: controls, cards, large containers.
public enum GioRadius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 14
}

/// Typography roles on SF Pro; numbers use the rounded design.
public enum GioFont {
    public static let pageTitle = Font.system(size: 22, weight: .bold)
    public static let sectionTitle = Font.system(size: 13, weight: .semibold)
    public static let headline = Font.system(size: 13, weight: .semibold)
    public static let body = Font.system(size: 13)
    public static let callout = Font.system(size: 12)
    public static let caption = Font.system(size: 11)
    public static let captionEmphasis = Font.system(size: 11, weight: .medium)
    public static let metric = Font.system(size: 26, weight: .semibold, design: .rounded)
    public static let metricSmall = Font.system(size: 17, weight: .semibold, design: .rounded)
    public static let keycap = Font.system(size: 12, weight: .medium, design: .rounded)
    public static let mono = Font.system(size: 11, design: .monospaced)
}

/// Semantic colors only: system colors, resolved per appearance.
public enum GioColor {
    /// Behind every page (System Settings' window background).
    public static let page = Color(nsColor: .windowBackgroundColor)
    /// Grouped card surface: a faint label tint over the page, like
    /// System Settings' grouped sections, in both appearances.
    public static let card = Color(nsColor: NSColor(name: "GioCard") { appearance in
        NSColor.labelColor.withAlphaComponent(appearance.isDark ? 0.055 : 0.03)
    })
    /// Raised surface on top of a card or well (keycaps, miniature tiles).
    public static let raised = Color(nsColor: NSColor(name: "GioRaised") { appearance in
        appearance.isDark
            ? NSColor.labelColor.withAlphaComponent(0.13)
            : NSColor.controlBackgroundColor
    })
    /// Hairline around cards and tiles.
    public static let hairline = Color(nsColor: .separatorColor)
    /// Recessed wells (canvas backdrop, track behind a strip).
    public static let well = Color(nsColor: NSColor(name: "GioWell") { appearance in
        appearance.isDark
            ? NSColor.black.withAlphaComponent(0.22)
            : NSColor.labelColor.withAlphaComponent(0.045)
    })
    public static let primaryText = Color.primary
    public static let secondaryText = Color.secondary
    public static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    public static let ok = Color(nsColor: .systemGreen)
    public static let warning = Color(nsColor: .systemOrange)
    public static let error = Color(nsColor: .systemRed)
    public static let info = Color(nsColor: .systemBlue)
    public static let neutral = Color(nsColor: .secondaryLabelColor)

    /// A status color as text: darkened in light mode so it reads on its
    /// own 14% tint, unchanged in dark mode.
    public static func ink(_ base: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? base : (base.blended(withFraction: 0.28, of: .black) ?? base)
        })
    }

    public static func tint(_ tint: SectionTint) -> Color {
        switch tint {
        case .blue: return Color(nsColor: .systemBlue)
        case .indigo: return Color(nsColor: .systemIndigo)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .orange: return Color(nsColor: .systemOrange)
        case .green: return Color(nsColor: .systemGreen)
        case .gray: return Color(nsColor: .systemGray)
        case .teal: return Color(nsColor: .systemTeal)
        case .cyan: return Color(nsColor: .systemCyan)
        }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua]).map {
            [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0)
        } ?? false
    }
}

extension Color {
    /// A config color (sRGB) as a SwiftUI color.
    public init(theme: ThemeColor) {
        self.init(.sRGB, red: theme.red, green: theme.green, blue: theme.blue, opacity: 1)
    }
}

// MARK: - Accent

private struct GioAccentKey: EnvironmentKey {
    static let defaultValue = FocusRingSectionConfig.defaultColor
}

extension EnvironmentValues {
    /// Gio's accent: the focus-ring color the session runs with.
    public var gioAccent: ThemeColor {
        get { self[GioAccentKey.self] }
        set { self[GioAccentKey.self] = newValue }
    }
}

/// Resolved accent colors for the current appearance.
public struct AccentPalette {
    /// The raw accent, for fills and highlights.
    public let fill: Color
    /// Legible as text and strokes on the page background.
    public let ink: Color
    /// Text on top of `fill`: opaque black or white, ≥ 4.5:1 on any accent.
    /// Use it at full opacity; de-emphasize with weight or size instead.
    public let onFill: Color
    /// A vertical gradient of the accent for marks, and the glyph that reads
    /// on both of its ends.
    public let gradient: LinearGradient
    public let onGradient: Color

    public init(accent: ThemeColor, colorScheme: ColorScheme) {
        fill = Color(theme: accent)
        ink = Color(theme: accentInk(accent, scheme: colorScheme == .dark ? .dark : .light))
        onFill = Color(theme: accentForegroundColor(accent))
        let stops = accentGradientStops(accent)
        gradient = LinearGradient(colors: stops.map { Color(theme: $0) }, startPoint: .top, endPoint: .bottom)
        onGradient = Color(theme: accentForegroundColor(onFills: stops))
    }
}
