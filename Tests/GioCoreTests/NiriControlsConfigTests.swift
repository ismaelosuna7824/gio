import XCTest
@testable import GioCore

/// Config, action names and key spellings for the Niri-style controls.
final class NiriControlsConfigTests: XCTestCase {
    private func parsed(_ text: String) -> (GioConfig, [String])? {
        if case .success(let value) = parseGioConfig(text) { return value }
        return nil
    }

    func testPresetDefaults() {
        XCTAssertEqual(
            defaultGioConfig().layout.presetColumnWidths,
            [.proportion(0.33333), .proportion(0.5), .proportion(0.66667)]
        )
    }

    func testPresetListParsesFractionsAndPoints() throws {
        let (config, warnings) = try XCTUnwrap(parsed("""
        [layout]
        preset-column-widths = [0.25, 0.5, 800]
        """))
        XCTAssertEqual(config.layout.presetColumnWidths, [.proportion(0.25), .proportion(0.5), .points(800)])
        XCTAssertTrue(warnings.isEmpty)
    }

    func testPresetListRejectsBadValues() {
        for text in [
            "[layout]\npreset-column-widths = []",
            "[layout]\npreset-column-widths = [0.5, -1]",
            "[layout]\npreset-column-widths = 0.5",
            "[layout]\npreset-column-widths = [0.5, \"x\"]",
            "[layout]\npreset-column-widths = [0.5,",
        ] {
            guard case .failure(let errors) = parseGioConfig(text) else {
                return XCTFail("expected failure for \(text)")
            }
            XCTAssertTrue(
                errors.messages.contains { $0.contains("layout.preset-column-widths") || $0.contains("cannot parse") },
                "\(errors.messages)"
            )
        }
    }

    /// NC-08: `preset-window-heights`, same rule as the widths.
    func testPresetWindowHeightsDefaultParseAndRejection() throws {
        XCTAssertEqual(defaultGioConfig().layout.presetWindowHeights, defaultPresetWindowHeights)
        let (config, warnings) = try XCTUnwrap(parsed("""
        [layout]
        preset-window-heights = [0.25, 0.75, 400]
        """))
        XCTAssertEqual(config.layout.presetWindowHeights, [.proportion(0.25), .proportion(0.75), .points(400)])
        XCTAssertTrue(warnings.isEmpty)
        for text in [
            "[layout]\npreset-window-heights = []",
            "[layout]\npreset-window-heights = [0.5, 0]",
            "[layout]\npreset-window-heights = 0.5",
        ] {
            guard case .failure(let errors) = parseGioConfig(text) else {
                return XCTFail("expected failure for \(text)")
            }
            XCTAssertTrue(errors.messages.contains { $0.contains("layout.preset-window-heights") }, "\(errors.messages)")
        }
        XCTAssertTrue(defaultConfigTemplate().contains("preset-window-heights = [0.33333, 0.5, 0.66667]"))
    }

    func testActionNames() {
        XCTAssertEqual(parseActionName("switch-preset-column-width"), .switchPresetColumnWidth)
        XCTAssertEqual(parseActionName("set-column-width-minus"), .shrinkColumnWidth)
        XCTAssertEqual(parseActionName("set-column-width-plus"), .growColumnWidth)
        for name in ["switch-preset-column-width", "set-column-width-minus", "set-column-width-plus"] {
            XCTAssertTrue(validActionNames().contains(name))
        }
    }

    func testKeySpellings() {
        XCTAssertEqual(parseHotkey("Alt+Minus"), HotkeyCombo(modifiers: [.alt], key: "Minus"))
        XCTAssertEqual(parseHotkey("Alt+-"), HotkeyCombo(modifiers: [.alt], key: "Minus"))
        XCTAssertEqual(parseHotkey("Alt+="), HotkeyCombo(modifiers: [.alt], key: "Equal"))
        XCTAssertEqual(parseHotkey("alt+equal"), HotkeyCombo(modifiers: [.alt], key: "Equal"))
        XCTAssertEqual(parseHotkey("Alt+["), HotkeyCombo(modifiers: [.alt], key: "BracketLeft"))
        XCTAssertEqual(parseHotkey("Alt+]"), HotkeyCombo(modifiers: [.alt], key: "BracketRight"))
    }

    func testDefaultBindingsForWidthControls() {
        let dispatcher = HotkeyDispatcher()
        XCTAssertEqual(dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "R")), .switchPresetColumnWidth)
        XCTAssertEqual(dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "Minus")), .shrinkColumnWidth)
        XCTAssertEqual(dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "Equal")), .growColumnWidth)
    }

    func testTemplateDocumentsPresetsAndParsesClean() throws {
        let template = defaultConfigTemplate()
        XCTAssertTrue(template.contains("preset-column-widths"))
        let (_, warnings) = try XCTUnwrap(parsed(template))
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }
}
