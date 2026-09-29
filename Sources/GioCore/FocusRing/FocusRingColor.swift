import Foundation

/// 8-bit sRGB components of a `ThemeColor`.
public struct RGBBytes: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

extension ThemeColor {
    /// Components rounded to bytes; out-of-range values clamp.
    public var rgbBytes: RGBBytes {
        func byte(_ value: Double) -> UInt8 {
            UInt8(min(max((value * 255).rounded(), 0), 255))
        }
        return RGBBytes(red: byte(red), green: byte(green), blue: byte(blue))
    }

    public init(rgbBytes: RGBBytes) {
        self.init(
            red: Double(rgbBytes.red) / 255, green: Double(rgbBytes.green) / 255,
            blue: Double(rgbBytes.blue) / 255
        )
    }

    /// Canonical config spelling: `#rrggbb`.
    public var lowercaseHex: String {
        let bytes = rgbBytes
        return String(format: "#%02x%02x%02x", bytes.red, bytes.green, bytes.blue)
    }
}

public struct HexColorError: Error, Equatable, Sendable {
    public let message: String
}

/// `#RGB`, `RGB`, `#RRGGBB` or `RRGGBB` (any case) to `#rrggbb`.
public func normalizedHexColor(_ text: String) -> Result<String, HexColorError> {
    guard let color = ThemeColor(hex: text) else {
        return .failure(HexColorError(message: "Ring color must be a hex color like #7fc8ff."))
    }
    return .success(color.lowercaseHex)
}

/// Swatches offered next to the picker; the first is Niri's default blue.
public let focusRingColorPresets: [String] = [
    "#7fc8ff", "#ffc87f", "#a6e3a1", "#f38ba8", "#cba6f7", "#89b4fa", "#ffffff",
]
