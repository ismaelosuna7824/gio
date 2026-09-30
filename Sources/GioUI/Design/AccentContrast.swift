import Foundation
import GioCore

/// Pure color math behind the accent: WCAG relative luminance and contrast,
/// the text color that reads on an accent fill, and an "ink" variant of the
/// accent that stays legible as text or strokes on each appearance.

/// Light or dark appearance, independent of SwiftUI so the math stays pure.
public enum AppearanceScheme: Equatable, Sendable {
    case light, dark
}

/// Which text color reads on an accent-filled surface.
public enum AccentForeground: Equatable, Sendable {
    case light, dark
}

/// Representative window background per appearance (the darker/lighter of
/// the grouped backgrounds, i.e. the harder case for contrast).
public let lightCanvas = ThemeColor(red: 236 / 255, green: 236 / 255, blue: 236 / 255)
public let darkCanvas = ThemeColor(red: 44 / 255, green: 44 / 255, blue: 46 / 255)

/// WCAG 2 relative luminance of an sRGB color, 0 (black) to 1 (white).
public func relativeLuminance(_ color: ThemeColor) -> Double {
    func linear(_ channel: Double) -> Double {
        let c = min(max(channel, 0), 1)
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
}

/// WCAG contrast ratio, 1 to 21, order-independent.
public func contrastRatio(_ lhs: ThemeColor, _ rhs: ThemeColor) -> Double {
    let a = relativeLuminance(lhs)
    let b = relativeLuminance(rhs)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// Text on an accent fill: whichever of black or white contrasts more.
public func foregroundOnAccent(_ accent: ThemeColor) -> AccentForeground {
    let black = ThemeColor(red: 0, green: 0, blue: 0)
    let white = ThemeColor(red: 1, green: 1, blue: 1)
    return contrastRatio(accent, black) >= contrastRatio(accent, white) ? .dark : .light
}

/// The accent as ink (text, strokes, glyphs) on the given appearance:
/// unchanged when it already reaches 3:1 against the canvas, otherwise mixed
/// toward black (light mode) or white (dark mode) in small steps until it
/// does. Keeps the hue recognizable while guaranteeing legibility.
public func accentInk(_ accent: ThemeColor, scheme: AppearanceScheme) -> ThemeColor {
    let canvas = scheme == .light ? lightCanvas : darkCanvas
    let target: Double = scheme == .light ? 0 : 1
    var amount = 0.0
    var ink = accent
    while contrastRatio(ink, canvas) < 3, amount < 1 {
        amount = min(amount + 0.05, 1)
        ink = ThemeColor(
            red: accent.red + (target - accent.red) * amount,
            green: accent.green + (target - accent.green) * amount,
            blue: accent.blue + (target - accent.blue) * amount
        )
    }
    return ink
}
