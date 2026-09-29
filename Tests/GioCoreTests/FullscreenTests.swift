import XCTest
@testable import GioCore

/// NC-03: real (non-Space) fullscreen through the layout pipeline.
final class FullscreenTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    // Dock inset at the bottom (80) and menu bar at the top (24), Cocoa y-up.
    private let usable = CGRect(x: 0, y: 80, width: 1800, height: 896)
    private let engine = ScrollableLayoutEngine(config: LayoutConfig(defaultColumnWidth: 880))

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func workspace(focused: UInt64 = 2) -> Workspace {
        Workspace(
            id: WorkspaceID(1),
            columns: [
                Column(id: ColumnID(1), width: 0, windows: [id(1)]),
                Column(id: ColumnID(2), width: 0, windows: [id(2), id(3)]),
                Column(id: ColumnID(3), width: 0, windows: [id(4)]),
            ],
            focusedColumn: 1,
            focusedWindow: id(focused)
        )
    }

    private func registry() throws -> WindowRegistry {
        let registry = WindowRegistry()
        for element in 1...4 as ClosedRange<UInt64> {
            try registry.register(ManagedWindow(
                id: id(element), pid: 10, application: "App", title: "",
                frame: CGRect(x: 0, y: 0, width: 100, height: 100), mode: .tiled
            ))
        }
        return registry
    }

    func testFullscreenFrameSpansDisplayUnderMenuBar() {
        let frame = fullscreenFrame(display: display, usable: usable)
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1800, height: 976))
        // Without insets it is the whole display.
        XCTAssertEqual(fullscreenFrame(display: display, usable: display), display)
    }

    func testFullscreenFrameInsetsByTheGapAndStaysUnderTheMenuBar() {
        let frame = fullscreenFrame(display: display, usable: usable, gap: 8)
        XCTAssertEqual(frame, CGRect(x: 8, y: 8, width: 1784, height: 960))
        XCTAssertEqual(frame.maxY, usable.maxY - 8)
        XCTAssertEqual(fullscreenFrame(display: display, usable: usable, gap: 0), fullscreenFrame(display: display, usable: usable))
    }

    func testFullscreenFrameNeverCollapsesWhenTheGapIsHuge() {
        let frame = fullscreenFrame(display: CGRect(x: 0, y: 0, width: 100, height: 100), usable: CGRect(x: 0, y: 0, width: 100, height: 90), gap: 64)
        XCTAssertGreaterThanOrEqual(frame.width, 0)
        XCTAssertGreaterThanOrEqual(frame.height, 0)
    }

    func testPlannerUsesTheLayoutFullscreenGap() throws {
        let gapped = ScrollableLayoutEngine(config: LayoutConfig(defaultColumnWidth: 880, fullscreenGap: 12))
        let planned = try planDisplayLayout(
            workspace: workspace(), modes: [id(2): .fullscreen], engine: gapped,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(planned.plan.visible, [id(2): fullscreenFrame(display: display, usable: usable, gap: 12)])
    }

    func testConfigFullscreenGapDefaultsToGapsAndCanBeOverridden() throws {
        var config = GioConfig()
        XCTAssertEqual(config.makeLayoutConfig(viewportWidth: 1800).fullscreenGap, 8)
        config = try parseGioConfig("[layout]\ngaps = 5\n").get().0
        XCTAssertEqual(config.makeLayoutConfig(viewportWidth: 1800).fullscreenGap, 5)
        config = try parseGioConfig("[layout]\ngaps = 5\nfullscreen-gap = 0\n").get().0
        XCTAssertEqual(config.makeLayoutConfig(viewportWidth: 1800).fullscreenGap, 0)
        config = try parseGioConfig("[layout]\nfullscreen-gap = 20\n").get().0
        XCTAssertEqual(config.layout.fullscreenGap, 20)
    }

    func testConfigRejectsOutOfRangeFullscreenGap() {
        for doc in ["[layout]\nfullscreen-gap = -1\n", "[layout]\nfullscreen-gap = 65\n", "[layout]\nfullscreen-gap = \"x\"\n"] {
            switch parseGioConfig(doc) {
            case .success: XCTFail("expected an error for \(doc)")
            case .failure(let errors): XCTAssertTrue(errors.messages.joined().contains("layout.fullscreen-gap"), doc)
            }
        }
    }

    func testSettingsFormFullscreenGap() {
        var form = LayoutSettingsForm(config: LayoutSectionConfig())
        XCTAssertTrue(form.fullscreenGapFollowsGaps)
        XCTAssertTrue(form.edits.contains(.remove(table: "layout", key: "fullscreen-gap")))
        form.fullscreenGapFollowsGaps = false
        form.fullscreenGap = 16
        XCTAssertTrue(form.edits.contains(.set(table: "layout", key: "fullscreen-gap", value: .number(16))))
        form.fullscreenGap = 65
        XCTAssertFalse(form.problems.isEmpty)
        let custom = LayoutSettingsForm(config: LayoutSectionConfig(fullscreenGap: 3))
        XCTAssertFalse(custom.fullscreenGapFollowsGaps)
        XCTAssertEqual(custom.fullscreenGap, 3)
    }

    func testTemplateMentionsFullscreenGapAndParsesClean() throws {
        XCTAssertTrue(defaultConfigTemplate().contains("fullscreen-gap"))
        XCTAssertTrue(try parseGioConfig(defaultConfigTemplate()).get().1.isEmpty)
    }

    func testPlannerFillsFocusedWindowAndParksEveryoneElse() throws {
        let modes: [WindowID: WindowMode] = [id(1): .tiled, id(2): .fullscreen, id(3): .tiled, id(4): .tiled]
        let planned = try planDisplayLayout(
            workspace: workspace(), modes: modes, engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(planned.plan.visible, [id(2): fullscreenFrame(display: display, usable: usable)])
        XCTAssertEqual(Set(planned.plan.parked.keys), [id(1), id(3), id(4)])
        for target in planned.plan.parked.values {
            XCTAssertFalse(target.frame.intersects(usable.insetBy(dx: 2, dy: 2)))
        }
    }

    func testLeavingFullscreenRestoresTheColumnLayout() throws {
        let tiled = try planDisplayLayout(
            workspace: workspace(), modes: [:], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        let full = try planDisplayLayout(
            workspace: workspace(), modes: [id(2): .fullscreen], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        let back = try planDisplayLayout(
            workspace: full.workspace, modes: [:], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(back.plan, tiled.plan)
        XCTAssertEqual(back.workspace, tiled.workspace)
    }

    func testBookTogglesRegistryModeAndRestoresPrevious() throws {
        let registry = try registry()
        var book = FullscreenBook()
        let frame = fullscreenFrame(display: display, usable: usable)
        XCTAssertTrue(try book.toggle(id(2), registry: registry, frame: frame))
        XCTAssertEqual(registry.find(id(2))?.mode, .fullscreen)
        XCTAssertTrue(book.isFullscreen(id(2)))
        XCTAssertFalse(try book.toggle(id(2), registry: registry, frame: frame))
        XCTAssertEqual(registry.find(id(2))?.mode, .tiled)
        XCTAssertEqual(registry.find(id(2))?.frame, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(book.isFullscreen(id(2)))
    }

    func testFocusingAwayReleasesFullscreen() throws {
        let registry = try registry()
        var book = FullscreenBook()
        try book.toggle(id(2), registry: registry, frame: display)
        XCTAssertEqual(book.release(keeping: [id(2)], registry: registry), [])
        XCTAssertEqual(registry.find(id(2))?.mode, .fullscreen)
        XCTAssertEqual(book.release(keeping: [id(4)], registry: registry), [id(2)])
        XCTAssertEqual(registry.find(id(2))?.mode, .tiled)
        XCTAssertFalse(book.isFullscreen(id(2)))
    }

    func testReleaseDropsRecordsWhoseModeChangedOrWindowVanished() throws {
        let registry = try registry()
        var book = FullscreenBook()
        try book.toggle(id(2), registry: registry, frame: display)
        try book.toggle(id(3), registry: registry, frame: display)
        _ = try registry.toggleFloating(for: id(2))   // leaves fullscreen -> tiled
        registry.remove(id(3))
        XCTAssertEqual(book.release(keeping: [id(2), id(3)], registry: registry), [])
        XCTAssertFalse(book.isFullscreen(id(2)))
        XCTAssertFalse(book.isFullscreen(id(3)))
        XCTAssertEqual(registry.find(id(2))?.mode, .tiled)
    }

    func testUnknownWindowThrows() throws {
        var book = FullscreenBook()
        XCTAssertThrowsError(try book.toggle(id(99), registry: try registry(), frame: display))
    }

    func testFloatingIsBoundByDefault() {
        XCTAssertEqual(
            HotkeyDispatcher().action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "Space")),
            .toggleFloating
        )
        XCTAssertEqual(
            HotkeyDispatcher().action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "F")),
            .fullscreen
        )
        XCTAssertEqual(parseActionName("fullscreen-window"), .fullscreen)
        XCTAssertEqual(parseActionName("toggle-window-floating"), .toggleFloating)
    }
}
