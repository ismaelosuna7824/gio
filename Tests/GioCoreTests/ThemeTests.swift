import XCTest
@testable import GioCore

/// Plan §27: hex colors, built-ins, TOML loading, fallbacks.
final class ThemeTests: XCTestCase {
    func testHexParsing() {
        XCTAssertEqual(ThemeColor(hex: "#7AA2F7")!, ThemeColor(red: 122 / 255, green: 162 / 255, blue: 247 / 255))
        XCTAssertEqual(ThemeColor(hex: "fff")!, ThemeColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(ThemeColor(hex: "#000000")!, ThemeColor(red: 0, green: 0, blue: 0))
        XCTAssertNil(ThemeColor(hex: "blue"))
        XCTAssertNil(ThemeColor(hex: "#12"))
        XCTAssertNil(ThemeColor(hex: "#GGGGGG"))
        XCTAssertEqual(ThemeColor(hex: "#7aa2f7")!.hex, "#7AA2F7")
    }

    func testBuiltinPalettes() {
        let themes = builtinThemes()
        XCTAssertEqual(themes.map(\.name), ["tokyo-night", "catppuccin", "nord", "gruvbox"])
        XCTAssertEqual(themes[0].gaps, 8)
        XCTAssertEqual(themes[3].gaps, 6)
        XCTAssertEqual(defaultTheme().name, "tokyo-night")
    }

    func testFullThemeDocumentLoads() throws {
        let root = try themeDir(name: "custom", text: """
            [theme]
            name = "custom"

            [colors]
            background = "#111111"
            accent = "#ABC"

            [layout]
            gaps = 12
            border-width = 3

            [bar]
            text-size = 13

            [wallpaper]
            path = "/tmp/wall.jpg"

            [typography]
            family = "Mono"
            """)
        let (theme, messages) = loadTheme(named: "custom", from: root)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(theme.name, "custom")
        XCTAssertEqual(theme.background, ThemeColor(hex: "#111111"))
        XCTAssertEqual(theme.accent, ThemeColor(hex: "#AABBCC"))
        XCTAssertEqual(theme.gaps, 12)
        XCTAssertEqual(theme.borderWidth, 3)
        XCTAssertEqual(theme.barTextSize, 13)
        XCTAssertEqual(theme.wallpaper, "/tmp/wall.jpg")
        XCTAssertEqual(theme.fontFamily, "Mono")
        XCTAssertNil(theme.foreground)
    }

    func testInvalidThemeFallsBackWithMessages() throws {
        let root = try themeDir(name: "broken", text: "[colors]\nbackground = \"nope\"\n")
        let (theme, messages) = loadTheme(named: "broken", from: root)
        XCTAssertEqual(theme.name, "tokyo-night")
        XCTAssertFalse(messages.isEmpty)
    }

    func testUnknownThemeFallsBack() {
        let (theme, messages) = loadTheme(named: "nope", from: "/nonexistent/themes")
        XCTAssertEqual(theme.name, "tokyo-night")
        XCTAssertFalse(messages.isEmpty)
    }

    func testBuiltinLoadsWithoutDirectory() {
        let (theme, messages) = loadTheme(named: "Nord", from: "/nonexistent/themes")
        XCTAssertEqual(theme.name, "nord")
        XCTAssertTrue(messages.isEmpty)
    }

    func testUnknownKeysWarn() throws {
        let root = try themeDir(name: "odd", text: "[layout]\ngaps = 8\nwarp = 9\n[future]\nthing = 1\n")
        let (theme, messages) = loadTheme(named: "odd", from: root)
        XCTAssertEqual(theme.gaps, 8)
        XCTAssertEqual(messages.count, 2)
    }

    func testGapsResolution() {
        var theme = GioTheme(name: "x")
        XCTAssertEqual(theme.resolveGaps(fallback: 8), 8)
        theme.gaps = 4
        XCTAssertEqual(theme.resolveGaps(fallback: 8), 4)
        XCTAssertEqual(theme.resolveBorderWidth(), 2)
        let layout = theme.applying(to: LayoutConfig(padding: 8, gap: 8))
        XCTAssertEqual(layout.gap, 4)
        XCTAssertEqual(layout.padding, 4)
    }

    private func themeDir(name: String, text: String) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-theme-test-\(UUID().uuidString)").path
        let dir = (root as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try text.write(
            toFile: (dir as NSString).appendingPathComponent("theme.toml"),
            atomically: true, encoding: .utf8
        )
        return root
    }
}
