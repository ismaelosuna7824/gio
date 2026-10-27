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

/// Typography roles on SF Pro. Titles and numbers use the rounded design,
/// the app's take on the landing page's friendly display face.
public enum GioFont {
    public static let pageTitle = Font.system(size: 24, weight: .bold, design: .rounded)
    public static let sectionTitle = Font.system(size: 13, weight: .semibold, design: .rounded)
    public static let headline = Font.system(size: 13, weight: .semibold)
    public static let body = Font.system(size: 13)
    public static let callout = Font.system(size: 12)
    public static let caption = Font.system(size: 11)
    public static let captionEmphasis = Font.system(size: 11, weight: .medium)
    public static let metric = Font.system(size: 26, weight: .bold, design: .rounded)
    public static let metricSmall = Font.system(size: 17, weight: .semibold, design: .rounded)
    public static let keycap = Font.system(size: 12, weight: .medium, design: .rounded)
    public static let mono = Font.system(size: 11, design: .monospaced)
}

/// Gio's identity, shared with the landing page and taken from the mascot:
/// the chameleon's navy outline is the ink (the dark page), the cream of
/// the windows it holds is the paper (the light page), its mint skin is the
/// brand color, and its spots are the secondary hues.
public enum GioBrand {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
        )
    }

    /// One color per appearance.
    static func dynamic(_ name: String, dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { $0.isDark ? dark : light })
    }

    static let navyDeep = rgb(0x1B2036)
    /// The title bar of the windows the mascot holds (the landing's `--navy`).
    static let navy = rgb(0x2F3553)
    /// Text on `navy` in both appearances (the landing's window-bar cream).
    static let onNavy = rgb(0xF3F0E8)
    static let mint = rgb(0x7FD6B6)
    static let butter = rgb(0xFFD66E)
    static let coral = rgb(0xFF9B85)
    static let sky = rgb(0x8CC8F5)
    static let lilac = rgb(0xC2B2F2)

    /// The app's accent (chrome, selection, buttons): the mascot's mint.
    public static let accent = ThemeColor(red: 0x7F / 255, green: 0xD6 / 255, blue: 0xB6 / 255)
    /// Glyphs and text drawn on a spot color, in both appearances.
    public static let onSpot = Color(nsColor: navyDeep)
}

/// Semantic colors in Gio's palette, resolved per appearance.
public enum GioColor {
    /// Behind every page: navy ink (dark), cream paper (light).
    public static let page = GioBrand.dynamic("GioPage", dark: GioBrand.rgb(0x131629), light: GioBrand.rgb(0xFBF7EF))
    /// The sidebar, a step off the page.
    public static let sidebar = GioBrand.dynamic("GioSidebar", dark: GioBrand.rgb(0x171A30), light: GioBrand.rgb(0xF5EFE2))
    /// Grouped card surface.
    public static let card = GioBrand.dynamic("GioCard", dark: GioBrand.rgb(0x1B1F37), light: GioBrand.rgb(0xFFFDF8))
    /// Raised surface on top of a card or well (keycaps, miniature tiles).
    public static let raised = GioBrand.dynamic("GioRaised", dark: GioBrand.rgb(0x232842), light: GioBrand.rgb(0xF2ECDF))
    /// Hairline around cards and tiles.
    public static let hairline = GioBrand.dynamic(
        "GioHairline", dark: GioBrand.rgb(0xC4CCFF, 0.16), light: GioBrand.rgb(0x2F3553, 0.2)
    )
    /// Recessed wells (canvas backdrop, track behind a strip).
    public static let well = GioBrand.dynamic("GioWell", dark: GioBrand.rgb(0x0F1222), light: GioBrand.rgb(0xF0E9DB))
    public static let primaryText = GioBrand.dynamic(
        "GioPrimaryText", dark: GioBrand.rgb(0xF6F2E8), light: GioBrand.rgb(0x232842)
    )
    public static let secondaryText = GioBrand.dynamic(
        "GioSecondaryText", dark: GioBrand.rgb(0xAEB2C8), light: GioBrand.rgb(0x585E7E)
    )
    public static let tertiaryText = GioBrand.dynamic(
        "GioTertiaryText", dark: GioBrand.rgb(0x767B98), light: GioBrand.rgb(0x8D91A8)
    )
    /// Status hues are the mascot's spots: mint, butter, coral, sky.
    public static let ok = Color(nsColor: GioBrand.mint)
    public static let warning = Color(nsColor: GioBrand.butter)
    public static let error = Color(nsColor: GioBrand.coral)
    public static let info = Color(nsColor: GioBrand.sky)
    public static let neutral = secondaryText
    /// The status hues as text: the spot itself on navy, a deeper shade on
    /// cream so it reads on its own 14% tint.
    public static let okInk = GioBrand.dynamic("GioOkInk", dark: GioBrand.mint, light: GioBrand.rgb(0x1C9670))
    public static let warningInk = GioBrand.dynamic("GioWarningInk", dark: GioBrand.butter, light: GioBrand.rgb(0xA0700C))
    public static let errorInk = GioBrand.dynamic("GioErrorInk", dark: GioBrand.coral, light: GioBrand.rgb(0xC94A31))
    public static let infoInk = GioBrand.dynamic("GioInfoInk", dark: GioBrand.sky, light: GioBrand.rgb(0x2A78B8))
    /// Controls in the brand color (switches, sliders, prominent buttons,
    /// selections): the mascot's mint on navy, a deeper mint on cream.
    public static let accent = GioBrand.dynamic("GioAccent", dark: GioBrand.mint, light: GioBrand.rgb(0x1C9670))
    /// Text and glyphs on `accent`.
    public static let onAccent = GioBrand.dynamic("GioOnAccent", dark: GioBrand.navyDeep, light: GioBrand.rgb(0xFFFDF8))

    /// A section or app hue as a fill (tiles, swatches): the pastel spot in
    /// both appearances, with `GioBrand.onSpot` drawn on it.
    public static func tintFill(_ tint: SectionTint) -> Color {
        Color(nsColor: spot(tint))
    }

    /// A section or app hue as a symbol or text color: the spot on navy, a
    /// deeper shade of it on cream.
    public static func tint(_ tint: SectionTint) -> Color {
        let base = spot(tint)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? base : (base.blended(withFraction: 0.42, of: GioBrand.navyDeep) ?? base)
        })
    }

    private static func spot(_ tint: SectionTint) -> NSColor {
        switch tint {
        case .blue: return GioBrand.sky
        case .indigo: return GioBrand.rgb(0xA3B2F5)
        case .purple: return GioBrand.lilac
        case .pink: return GioBrand.coral
        case .orange: return GioBrand.butter
        case .green: return GioBrand.mint
        case .gray: return GioBrand.rgb(0xB4B8CE)
        case .teal: return GioBrand.rgb(0x6FD0C8)
        case .cyan: return GioBrand.rgb(0x7CD3E8)
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
    static let defaultValue = GioBrand.accent
}

extension EnvironmentValues {
    /// Gio's accent: the brand mint (`GioBrand.accent`). The focus ring
    /// keeps its own configurable color on screen.
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
