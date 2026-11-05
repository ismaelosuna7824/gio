import CoreGraphics
import XCTest
@testable import GioCore

/// SB-01: `[hooks]` and `[layout] reserved-top` (the room a custom bar
/// such as SketchyBar takes at the top of every display).
final class BarConfigTests: XCTestCase {
    func testHooksAreOffByDefault() {
        XCTAssertEqual(GioConfig().hooks, HooksSectionConfig())
        XCTAssertNil(GioConfig().hooks.onWorkspaceChange)
        XCTAssertNil(GioConfig().hooks.onWindowsChange)
        XCTAssertTrue(GioConfig().hooks.isEmpty)
    }

    func testHooksParse() throws {
        let (config, warnings) = try parseGioConfig("""
        [hooks]
        on-workspace-change = "sketchybar --trigger gio_workspace_change"
        on-windows-change = "sketchybar --trigger gio_windows_change # not a comment"
        """).get()
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.hooks.onWorkspaceChange, "sketchybar --trigger gio_workspace_change")
        XCTAssertEqual(config.hooks.onWindowsChange, "sketchybar --trigger gio_windows_change # not a comment")
        XCTAssertFalse(config.hooks.isEmpty)
    }

    func testEmptyHookIsOff() throws {
        let (config, _) = try parseGioConfig("[hooks]\non-workspace-change = \"\"\non-windows-change = \"  \"\n").get()
        XCTAssertNil(config.hooks.onWorkspaceChange)
        XCTAssertNil(config.hooks.onWindowsChange)
        XCTAssertTrue(config.hooks.isEmpty)
    }

    func testNonStringHookIsAnError() {
        for doc in ["[hooks]\non-workspace-change = 3\n", "[hooks]\non-windows-change = true\n"] {
            switch parseGioConfig(doc) {
            case .success: XCTFail("expected an error for \(doc)")
            case .failure(let errors):
                XCTAssertTrue(errors.messages.joined().contains("expects a shell command in quotes"), "\(errors)")
            }
        }
    }

    func testUnknownHookKeyWarns() throws {
        let (_, warnings) = try parseGioConfig("[hooks]\non-focus-change = \"x\"\n").get()
        XCTAssertEqual(warnings, ["line 2: unknown hooks key 'on-focus-change', ignored"])
    }

    func testReservedTopParsesAndClampsWithAWarning() throws {
        XCTAssertEqual(GioConfig().layout.reservedTop, 0)
        XCTAssertEqual(try parseGioConfig("[layout]\nreserved-top = 32\n").get().0.layout.reservedTop, 32)
        let (high, highWarnings) = try parseGioConfig("[layout]\nreserved-top = 500\n").get()
        XCTAssertEqual(high.layout.reservedTop, 200)
        XCTAssertEqual(highWarnings, ["line 2: layout.reserved-top expects 0 to 200 points, clamped to 200"])
        let (low, lowWarnings) = try parseGioConfig("[layout]\nreserved-top = -4\n").get()
        XCTAssertEqual(low.layout.reservedTop, 0)
        XCTAssertEqual(lowWarnings, ["line 2: layout.reserved-top expects 0 to 200 points, clamped to 0"])
        switch parseGioConfig("[layout]\nreserved-top = \"tall\"\n") {
        case .success: XCTFail("a string is an error")
        case .failure(let errors): XCTAssertTrue(errors.messages.joined().contains("layout.reserved-top"))
        }
        XCTAssertEqual(try parseGioConfig("[layout]\nreserved-top = 28\n").get().0.makeLayoutConfig().reservedTop, 28)
    }

    func testEqualityCoversHooks() {
        var config = GioConfig()
        config.hooks.onWindowsChange = "true"
        XCTAssertNotEqual(config, GioConfig())
    }

    func testTemplateMentionsHooksAndReservedTopAndParsesClean() throws {
        let template = defaultConfigTemplate()
        XCTAssertTrue(template.contains("[hooks]"))
        XCTAssertTrue(template.contains("# on-workspace-change = "))
        XCTAssertTrue(template.contains("# on-windows-change = "))
        XCTAssertTrue(template.contains("# reserved-top = "))
        let (config, warnings) = try parseGioConfig(template).get()
        XCTAssertEqual(warnings, [])
        XCTAssertTrue(config.hooks.isEmpty, "the template's hooks are commented out")
        XCTAssertEqual(config.layout.reservedTop, 0)
    }

    func testLayoutFormWritesReservedTop() {
        var form = LayoutSettingsForm(config: LayoutSectionConfig(reservedTop: 24))
        XCTAssertEqual(form.reservedTop, 24)
        XCTAssertTrue(form.edits.contains(.set(table: "layout", key: "reserved-top", value: .number(24))))
        form.reservedTop = 201
        XCTAssertTrue(form.problems.contains("Space for a custom bar must be 0 to 200 points."))
        form.reservedTop = 0
        XCTAssertTrue(form.problems.isEmpty)
    }

    // MARK: - Frame math

    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// Cocoa: the menu bar takes the top 37 pt, so the visible frame ends at 945.
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)

    func testReservedTopShrinksTheUsableFrameFromTheTop() {
        XCTAssertEqual(
            usableFrame(visible: visible, reservedTop: 32), CGRect(x: 0, y: 0, width: 1512, height: 913)
        )
        XCTAssertEqual(usableFrame(visible: visible, reservedTop: 0), visible)
        // A hidden menu bar: the visible frame reaches the display's top.
        XCTAssertEqual(
            usableFrame(visible: display, reservedTop: 32), CGRect(x: 0, y: 0, width: 1512, height: 950)
        )
        // A display above the primary one (Cocoa y up): only maxY moves.
        let upper = CGRect(x: 200, y: 982, width: 1920, height: 1055)
        XCTAssertEqual(usableFrame(visible: upper, reservedTop: 40), CGRect(x: 200, y: 982, width: 1920, height: 1015))
        // Never below half the visible height.
        XCTAssertEqual(usableFrame(visible: CGRect(x: 0, y: 0, width: 100, height: 100), reservedTop: 200).height, 50)
    }

    func testFullscreenStillCoversTheReservedBand() {
        let usable = usableFrame(visible: visible, reservedTop: 32)
        XCTAssertEqual(
            fullscreenFrame(display: display, usable: usable, reservedTop: 32),
            CGRect(x: 0, y: 0, width: 1512, height: 945), "up to the menu bar, over the custom bar's band"
        )
        XCTAssertEqual(
            fullscreenFrame(display: display, usable: usableFrame(visible: display, reservedTop: 32), reservedTop: 32),
            display, "hidden menu bar: the whole display"
        )
    }

    func testScrollingAndDwindleLayOutBelowTheReservedBand() throws {
        let usable = usableFrame(visible: visible, reservedTop: 32)
        let one = WindowID(pid: 1, elementID: 1)
        let two = WindowID(pid: 1, elementID: 2)
        var workspace = Workspace(id: WorkspaceID(1))
        workspace.columns = [
            Column(id: ColumnID(1), width: 600, windows: [one]), Column(id: ColumnID(2), width: 600, windows: [two]),
        ]
        workspace.focusedWindow = one
        let config = GioConfig(layout: LayoutSectionConfig(fullscreenGap: 0, reservedTop: 32)).makeLayoutConfig()
        let modes: [WindowID: WindowMode] = [one: .tiled, two: .tiled]
        let scrolling = try planDisplayLayout(
            workspace: workspace, modes: modes, engine: ScrollableLayoutEngine(config: config),
            viewport: usable, display: display, otherDisplays: []
        )
        for frame in scrolling.plan.visible.values {
            XCTAssertLessThanOrEqual(frame.maxY, usable.maxY - config.padding + 0.5)
        }
        workspace.layout = .dwindle
        let dwindle = try planDisplayLayout(
            workspace: workspace, modes: modes, engine: ScrollableLayoutEngine(config: config),
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(dwindle.plan.visible.count, 2)
        for frame in dwindle.plan.visible.values {
            XCTAssertLessThanOrEqual(frame.maxY, usable.maxY - config.padding + 0.5)
        }
        let covering = try planDisplayLayout(
            workspace: workspace, modes: [one: .fullscreen, two: .tiled], engine: ScrollableLayoutEngine(config: config),
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(covering.plan.visible[one], CGRect(x: 0, y: 0, width: 1512, height: 945))
    }
}
