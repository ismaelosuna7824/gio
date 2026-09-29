import XCTest
@testable import GioCore

/// Plan §20: defaults, full valid doc, invalid values fall back to defaults
/// with messages, unknown keys warn, missing file is silent defaults.
final class ConfigTests: XCTestCase {
    private let full = """
        # Gio config
        [layout]
        gaps = 8
        padding = 12
        default-column-width = 0.5
        center-focused-column = true

        [behavior]
        focus-follows-mouse = false
        mouse-follows-focus = true

        [animations]
        enabled = false

        [keybindings]
        "Alt+H" = "focus-left"
        "Alt+Shift+L" = "move-right"
        "Alt+3" = "workspace 3"
        "Alt+F" = "fullscreen"

        [[window-rules]]
        app = "Calculator"
        mode = "floating"

        [[window-rules]]
        app = "Code"
        workspace = 1
        """

    func testDefaultsMirrorPlanExample() {
        let config = defaultGioConfig()
        XCTAssertEqual(config.layout.gaps, 8)
        XCTAssertEqual(config.layout.padding, 8)
        XCTAssertEqual(config.layout.defaultColumnWidthFraction, 0.5)
        XCTAssertNil(config.layout.defaultColumnWidthPoints)
        XCTAssertEqual(config.layout.centerFocusedColumn, .never)
        XCTAssertFalse(config.behavior.focusFollowsMouse)
        XCTAssertTrue(config.behavior.mouseFollowsFocus)
        XCTAssertTrue(config.animations.enabled)
        XCTAssertTrue(config.keybindings.isEmpty)
        XCTAssertTrue(config.rules.isEmpty)
    }

    func testFullDocumentParses() throws {
        let (config, warnings) = try parseGioConfig(full).get()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(config.layout.padding, 12)
        XCTAssertEqual(config.rules, [
            WindowRule(app: "Calculator", mode: .floating, workspace: nil),
            WindowRule(app: "Code", mode: nil, workspace: 1),
        ])
        XCTAssertEqual(config.keybindings.count, 4)
        let dispatcher = config.makeDispatcher()
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "H")), .focusLeft
        )
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "F")), .fullscreen
        )
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "J")), .focusDown
        )
        XCTAssertEqual(config.resolveDefaultColumnWidth(viewportWidth: 1000), 484)
        let layout = config.makeLayoutConfig(viewportWidth: 1000)
        XCTAssertEqual(layout.gap, 8)
        XCTAssertEqual(layout.padding, 12)
        XCTAssertEqual(layout.defaultColumnWidth, 484)
    }

    func testAbsoluteWidthResolves() throws {
        let (config, _) = try parseGioConfig("[layout]\ndefault-column-width = 640\n").get()
        XCTAssertNil(config.layout.defaultColumnWidthFraction)
        XCTAssertEqual(config.layout.defaultColumnWidthPoints, 640)
        XCTAssertEqual(config.resolveDefaultColumnWidth(viewportWidth: 1000), 640)
    }

    func testInvalidValuesFallBackToDefaultsWithMessages() {
        for doc in [
            "[layout]\ngaps = -1\n",
            "[layout]\npadding = \"wide\"\n",
            "[layout]\ndefault-column-width = 0\n",
            "[behavior]\nfocus-follows-mouse = \"yes\"\n",
            "[keybindings]\n\"Alt+H\" = \"fly\"\n",
            "[keybindings]\n\"H\" = \"focus-left\"\n",
            "[[window-rules]]\nmode = \"floating\"\n",
            "[[window-rules]]\napp = \"X\"\nmode = \"spiral\"\n",
            "[[window-rules]]\napp = \"X\"\nworkspace = 42\n",
            "stray = 1\n",
            "[layout\n",
        ] {
            let result = parseGioConfig(doc)
            guard case .failure(let errors) = result else {
                XCTFail("expected failure for: \(doc)")
                return
            }
            XCTAssertFalse(errors.messages.isEmpty, "no message for: \(doc)")
        }
    }

    func testLoaderFallsBackToDefaultsOnInvalid() {
        let path = writeTemp("gaps = -1\n")
        let (config, messages) = loadGioConfig(at: path)
        XCTAssertEqual(config.layout.gaps, 8)
        XCTAssertFalse(messages.isEmpty)
    }

    func testUnknownKeysWarnWithoutFailing() throws {
        let doc = "[layout]\ngaps = 4\ngasp = 4\n[future]\nthing = 1\n"
        let (config, warnings) = try parseGioConfig(doc).get()
        XCTAssertEqual(config.layout.gaps, 4)
        XCTAssertEqual(warnings.count, 2)
    }

    func testMissingFileIsSilentDefaults() {
        let (config, messages) = loadGioConfig(at: "/nonexistent/gio-test-config.toml")
        XCTAssertEqual(config.layout.gaps, 8)
        XCTAssertTrue(messages.isEmpty)
    }

    func testRoundTripThroughFile() throws {
        let path = writeTemp(full)
        let (config, messages) = loadGioConfig(at: path)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(config.layout.padding, 12)
        XCTAssertEqual(config.rules.count, 2)
    }

    func testActionNames() {
        XCTAssertEqual(parseActionName("workspace 2"), .workspace(2))
        XCTAssertEqual(parseActionName("move-to-workspace 9"), .moveToWorkspace(9))
        XCTAssertNil(parseActionName("workspace x"))
        XCTAssertNil(parseActionName("fly"))
        XCTAssertTrue(validActionNames().contains("toggle-floating"))
    }

    private func writeTemp(_ text: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-config-test-\(UUID().uuidString).toml")
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
