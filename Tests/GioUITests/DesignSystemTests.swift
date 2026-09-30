import GioCore
import XCTest
@testable import GioUI

/// DD-01: the pure pieces behind the design system — accent contrast,
/// the sidebar section table and keycap glyphs.
final class DesignSystemTests: XCTestCase {
    // MARK: - Accent contrast

    func testLuminanceOfBlackAndWhite() {
        XCTAssertEqual(relativeLuminance(ThemeColor(red: 0, green: 0, blue: 0)), 0, accuracy: 0.0001)
        XCTAssertEqual(relativeLuminance(ThemeColor(red: 1, green: 1, blue: 1)), 1, accuracy: 0.0001)
    }

    func testContrastRatioIsSymmetricAndMaximalForBlackOnWhite() {
        let black = ThemeColor(red: 0, green: 0, blue: 0)
        let white = ThemeColor(red: 1, green: 1, blue: 1)
        XCTAssertEqual(contrastRatio(black, white), 21, accuracy: 0.01)
        XCTAssertEqual(contrastRatio(white, black), 21, accuracy: 0.01)
    }

    func testForegroundOnLightAccentIsDark() {
        // Niri's default focus blue is light: white text would be unreadable.
        XCTAssertEqual(foregroundOnAccent(FocusRingSectionConfig.defaultColor), .dark)
        XCTAssertEqual(foregroundOnAccent(ThemeColor(hex: "#ffd60a")!), .dark)
    }

    func testForegroundOnDarkAccentIsLight() {
        XCTAssertEqual(foregroundOnAccent(ThemeColor(hex: "#0a3d91")!), .light)
        XCTAssertEqual(foregroundOnAccent(ThemeColor(hex: "#8e24aa")!), .light)
    }

    func testAccentInkReachesThreeToOneOnBothBackgrounds() {
        let accents = ["#7fc8ff", "#ffd60a", "#0a3d91", "#ffffff", "#000000", "#30d158"]
        for hex in accents {
            let accent = ThemeColor(hex: hex)!
            let light = accentInk(accent, scheme: .light)
            let dark = accentInk(accent, scheme: .dark)
            XCTAssertGreaterThanOrEqual(contrastRatio(light, lightCanvas), 3, "\(hex) light")
            XCTAssertGreaterThanOrEqual(contrastRatio(dark, darkCanvas), 3, "\(hex) dark")
        }
    }

    func testAccentInkKeepsAnAlreadyReadableAccent() {
        let deep = ThemeColor(hex: "#0a3d91")!
        XCTAssertEqual(accentInk(deep, scheme: .light), deep)
        let light = FocusRingSectionConfig.defaultColor
        XCTAssertEqual(accentInk(light, scheme: .dark), light)
    }

    // MARK: - Sections

    func testEverySectionHasAStyleWithSymbolAndTint() {
        for section in MainSection.allCases {
            let style = sectionStyle(section)
            XCTAssertFalse(style.symbol.isEmpty, "\(section)")
        }
        let tints = Set(MainSection.allCases.map { sectionStyle($0).tint })
        XCTAssertGreaterThanOrEqual(tints.count, 5, "sections should be visually distinct")
    }

    func testSidebarGroupsCoverEverySectionOnceInOrder() {
        let grouped = sidebarGroups.flatMap(\.sections)
        XCTAssertEqual(grouped, MainSection.allCases)
        XCTAssertEqual(sidebarGroups.map(\.title), ["General", "Keyboard", "Tiling", "Advanced"])
        XCTAssertEqual(sidebarGroups[2].sections, [.layout, .animations, .rules])
    }

    // MARK: - Keycaps

    func testKeycapGlyphsUseMacModifierOrderAndSymbols() {
        let combo = HotkeyCombo(modifiers: [.cmd, .shift, .alt, .ctrl], key: "H")
        XCTAssertEqual(keycapGlyphs(for: combo).map(\.text), ["⌃", "⌥", "⇧", "⌘", "H"])
        XCTAssertEqual(keycapGlyphs(for: combo).map(\.role), [.modifier, .modifier, .modifier, .modifier, .key])
    }

    func testNamedKeysAreWideAndSymbolKeysAreNot() {
        XCTAssertEqual(keycapGlyphs(for: HotkeyCombo(modifiers: [.alt], key: "Space")).last?.role, .wideKey)
        XCTAssertEqual(keycapGlyphs(for: HotkeyCombo(modifiers: [.alt], key: "Left")).last?.text, "←")
        XCTAssertEqual(keycapGlyphs(for: HotkeyCombo(modifiers: [.alt], key: "Left")).last?.role, .key)
        XCTAssertEqual(keycapGlyphs(for: HotkeyCombo(modifiers: [.alt], key: "F12")).last?.role, .wideKey)
    }

    func testModifierGlyphTable() {
        XCTAssertEqual(modifierGlyph(.cmd), "⌘")
        XCTAssertEqual(modifierGlyph(.alt), "⌥")
        XCTAssertEqual(modifierGlyph(.shift), "⇧")
        XCTAssertEqual(modifierGlyph(.ctrl), "⌃")
    }
}
