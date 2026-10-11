import XCTest
@testable import GioCore

/// DW-03: `[layout] default-layout`, `[dwindle]`, `[[workspace]] layout`:
/// parsing, validation (warnings that keep the default), the template, the
/// patcher, the Settings form, and how the session applies them.
final class DwindleConfigTests: XCTestCase {
    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> (GioConfig, [String]) {
        try parseGioConfig(text).get()
    }

    func testDefaults() {
        let config = GioConfig()
        XCTAssertEqual(config.layout.defaultLayout, .scrolling)
        XCTAssertEqual(config.dwindle, DwindleSectionConfig())
        XCTAssertEqual(config.dwindle.defaultSplitRatio, 1)
        XCTAssertEqual(config.dwindle.splitWidthMultiplier, 1)
        XCTAssertEqual(config.layoutDefaults, WorkspaceLayoutDefaults())
        XCTAssertEqual(config.makeLayoutConfig().dwindle, DwindleSettings())
    }

    func testValidValuesParse() throws {
        let (config, warnings) = try parse("""
        [layout]
        default-layout = "dwindle"
        [dwindle]
        default-split-ratio = 1.2
        split-width-multiplier = 1.5
        [[workspace]]
        name = "Code"
        layout = "dwindle"
        [[workspace]]
        name = "Web"
        layout = "scrolling"
        [[workspace]]
        name = "Chat"
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.layout.defaultLayout, .dwindle)
        XCTAssertEqual(config.dwindle.defaultSplitRatio, 1.2)
        XCTAssertEqual(config.dwindle.splitWidthMultiplier, 1.5)
        XCTAssertEqual(config.workspaces.map(\.layout), [.dwindle, .scrolling, nil])
        XCTAssertEqual(config.layoutDefaults, WorkspaceLayoutDefaults(kind: .dwindle, splitRatio: 1.2))
        XCTAssertEqual(config.makeLayoutConfig().dwindle, DwindleSettings(splitRatio: 1.2, splitWidthMultiplier: 1.5))
    }

    func testInvalidValuesWarnAndKeepTheDefaults() throws {
        let (config, warnings) = try parse("""
        [layout]
        default-layout = "bsp"
        gaps = 4
        [dwindle]
        default-split-ratio = 2.5
        split-width-multiplier = 0
        smart-split = true
        [[workspace]]
        name = "Code"
        layout = 3
        """)
        XCTAssertEqual(config.layout.defaultLayout, .scrolling)
        XCTAssertEqual(config.layout.gaps, 4, "the rest of the file applies")
        XCTAssertEqual(config.dwindle, DwindleSectionConfig())
        XCTAssertEqual(config.workspaces.map(\.name), ["Code"])
        XCTAssertNil(config.workspaces[0].layout)
        XCTAssertEqual(warnings, [
            "line 2: layout.default-layout expects \"scrolling\" or \"dwindle\", default kept",
            "line 5: dwindle.default-split-ratio expects a number from 0.1 to 1.9, default kept",
            "line 6: dwindle.split-width-multiplier expects a number from 0.1 to 10, default kept",
            "line 7: dwindle.smart-split is not supported (Gio has no pointer position when a window opens; use dwindle-preselect-*), ignored",
            "line 8: workspace layout expects \"scrolling\" or \"dwindle\", default layout kept",
        ])
        let (wrongType, typeWarnings) = try parse("[dwindle]\ndefault-split-ratio = \"wide\"\nother = 1\n")
        XCTAssertEqual(wrongType.dwindle, DwindleSectionConfig())
        XCTAssertEqual(typeWarnings, [
            "line 2: dwindle.default-split-ratio expects a number from 0.1 to 1.9, default kept",
            "line 3: unknown dwindle key 'other', ignored",
        ])
    }

    func testTheTemplateParsesWithTheDefaults() throws {
        let (config, warnings) = try parse(defaultConfigTemplate())
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.layout.defaultLayout, .scrolling)
        XCTAssertEqual(config.dwindle, DwindleSectionConfig())
        XCTAssertTrue(defaultConfigTemplate().contains("default-layout = \"scrolling\""))
        XCTAssertTrue(defaultConfigTemplate().contains("[dwindle]"))
    }

    func testPatchingKeepsCommentsAndRoundTrips() throws {
        let original = """
        # mine
        [layout]
        # keep me
        gaps = 8
        [[workspace]]
        name = "Code"
        icon = "hammer"
        """
        let edits: [ConfigEdit] = [
            .set(table: "layout", key: "default-layout", value: .string("dwindle")),
            .set(table: "dwindle", key: "default-split-ratio", value: .number(1.3)),
            .set(table: "dwindle", key: "split-width-multiplier", value: .number(0.8)),
            .updateWorkspace(index: 0, WorkspaceDefinition(name: "Code", icon: "hammer", layout: .dwindle)),
        ]
        let patched = try patchGioConfig(original, edits: edits).get()
        XCTAssertTrue(patched.text.contains("# mine"))
        XCTAssertTrue(patched.text.contains("# keep me"))
        XCTAssertTrue(patched.text.contains("layout = \"dwindle\""))
        XCTAssertEqual(patched.warnings, [])
        XCTAssertEqual(patched.config.layout.defaultLayout, .dwindle)
        XCTAssertEqual(patched.config.dwindle, DwindleSectionConfig(defaultSplitRatio: 1.3, splitWidthMultiplier: 0.8))
        XCTAssertEqual(patched.config.workspaces, [WorkspaceDefinition(name: "Code", icon: "hammer", layout: .dwindle)])
    }

    // MARK: - Settings form

    func testTheLayoutFormCarriesTheDwindleKeys() {
        var config = GioConfig()
        config.layout.defaultLayout = .dwindle
        config.dwindle = DwindleSectionConfig(defaultSplitRatio: 1.2, splitWidthMultiplier: 1.5)
        var form = LayoutSettingsForm(config: config.layout, dwindle: config.dwindle)
        XCTAssertEqual(form.defaultLayout, .dwindle)
        XCTAssertEqual(form.splitRatio, 1.2, accuracy: 1e-9)
        XCTAssertEqual(form.splitWidthMultiplier, 1.5, accuracy: 1e-9)
        XCTAssertEqual(form.problems, [])
        XCTAssertTrue(form.edits.contains(.set(table: "layout", key: "default-layout", value: .string("dwindle"))))
        XCTAssertTrue(form.edits.contains(.set(table: "dwindle", key: "default-split-ratio", value: .number(1.2))))
        XCTAssertTrue(form.edits.contains(.set(table: "dwindle", key: "split-width-multiplier", value: .number(1.5))))
        form.splitRatio = 2
        form.splitWidthMultiplier = 0
        XCTAssertEqual(form.problems, [
            "Dwindle split ratio must be 0.1 to 1.9.",
            "Dwindle width multiplier must be 0.1 to 10.",
        ])
        XCTAssertEqual(LayoutSettingsForm(config: LayoutSectionConfig()).defaultLayout, .scrolling)
    }

    // MARK: - The session applies it

    func testTheSessionAppliesDefaultsAndNamedLayoutsAndKeepsARuntimeToggle() {
        var config = GioConfig()
        config.layout.defaultLayout = .dwindle
        config.dwindle.defaultSplitRatio = 1.4
        config.workspaces = [WorkspaceDefinition(name: "Code", layout: .scrolling), WorkspaceDefinition(name: "Web")]
        var session = CommandSession(config: config)
        let code = session.manager.namedWorkspaceID("Code")!
        let web = session.manager.namedWorkspaceID("Web")!
        XCTAssertEqual(session.manager.workspace(id: code)?.layout, .scrolling, "its own layout")
        XCTAssertEqual(session.manager.workspace(id: web)?.layout, .dwindle, "the default layout")
        XCTAssertEqual(session.manager.layoutDefaults, WorkspaceLayoutDefaults(kind: .dwindle, splitRatio: 1.4))

        XCTAssertTrue(session.manager.setLayout(.dwindle, of: code))
        session.config = config
        XCTAssertEqual(session.manager.workspace(id: code)?.layout, .dwindle, "a reload that left the key alone keeps the toggle")
        config.workspaces[0].layout = .dwindle
        session.config = config
        config.workspaces[0].layout = .scrolling
        session.config = config
        XCTAssertEqual(session.manager.workspace(id: code)?.layout, .scrolling, "a changed key applies")
    }

    // MARK: - Motion (PF-M)

    func testDwindleTileChangesStayOnAccessibilityAndHiddenOnesUseTheWindowServer() {
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let id = WindowID(pid: 4, elementID: 1)
        let resized = WindowAnimation(
            id: id, from: CGRect(x: 10, y: 10, width: 980, height: 580),
            to: CGRect(x: 10, y: 10, width: 485, height: 580), duration: 0.2
        )
        let hidden = WindowAnimation(
            id: id, from: CGRect(x: 10, y: 10, width: 485, height: 580),
            to: CGRect(x: 10, y: -579, width: 485, height: 580), duration: 0.2
        )
        let planned = planMotionTransports([resized, hidden], viewports: [viewport], enabled: true, ownPID: 1)
        XCTAssertEqual(planned.map(\.transport), [.accessibility, .windowServer])
    }
}
