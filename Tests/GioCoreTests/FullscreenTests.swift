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
        XCTAssertEqual(config.makeLayoutConfig().fullscreenGap, 8)
        config = try parseGioConfig("[layout]\ngaps = 5\n").get().0
        XCTAssertEqual(config.makeLayoutConfig().fullscreenGap, 5)
        config = try parseGioConfig("[layout]\ngaps = 5\nfullscreen-gap = 0\n").get().0
        XCTAssertEqual(config.makeLayoutConfig().fullscreenGap, 0)
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

    func testFullscreenSurvivesFocusMovingAwayAndBack() throws {
        let registry = try registry()
        var book = FullscreenBook()
        let frame = fullscreenFrame(display: display, usable: usable)
        try book.toggle(id(2), registry: registry, frame: frame)
        let tiled = try planDisplayLayout(
            workspace: workspace(focused: 2), modes: [:], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )

        let focusedOnOther = try planDisplayLayout(
            workspace: workspace(focused: 4), modes: [id(2): .fullscreen], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertTrue(book.isFullscreen(id(2)))
        XCTAssertEqual(registry.find(id(2))?.mode, .fullscreen)
        XCTAssertNotEqual(focusedOnOther.plan.visible[id(4)], frame)
        XCTAssertEqual(plannedFrame(of: id(2), in: focusedOnOther)?.size, frame.size)

        let focusedBack = try planDisplayLayout(
            workspace: workspace(focused: 2), modes: [id(2): .fullscreen], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(focusedBack.plan.visible, [id(2): frame])

        XCTAssertFalse(try book.toggle(id(2), registry: registry, frame: frame))
        XCTAssertEqual(registry.find(id(2))?.mode, .tiled)
        let restored = try planDisplayLayout(
            workspace: workspace(focused: 2), modes: [:], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(restored.plan, tiled.plan)
    }

    func testFocusingAnotherWindowShowsItPerNormalLayoutRules() throws {
        let planned = try planDisplayLayout(
            workspace: workspace(focused: 4), modes: [id(2): .fullscreen], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        let fullscreen = fullscreenFrame(display: display, usable: usable)
        XCTAssertTrue(planned.plan.visible.values.allSatisfy { $0 != fullscreen })
        XCTAssertNotNil(planned.plan.visible[id(4)])
        XCTAssertTrue(planned.layout.frames.keys.contains(id(2)))
    }

    private func plannedFrame(of window: WindowID, in planned: DisplayLayoutPlan) -> CGRect? {
        planned.plan.visible[window] ?? planned.plan.parked[window]?.frame
    }

    func testUnfocusedFullscreenWindowKeepsItsFullscreenSize() throws {
        let fullscreen = fullscreenFrame(display: display, usable: usable)
        let modes: [WindowID: WindowMode] = [id(2): .fullscreen]
        let focusedOnFullscreen = try planDisplayLayout(
            workspace: workspace(focused: 2), modes: modes, engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(focusedOnFullscreen.plan.visible, [id(2): fullscreen])

        let focusedOnNeighbour = try planDisplayLayout(
            workspace: workspace(focused: 4), modes: modes, engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(focusedOnNeighbour.layout.frames[id(2)]?.size, fullscreen.size)
        XCTAssertEqual(plannedFrame(of: id(2), in: focusedOnNeighbour)?.size, fullscreen.size)
        XCTAssertNotNil(focusedOnNeighbour.plan.visible[id(4)])
        XCTAssertNotEqual(plannedFrame(of: id(2), in: focusedOnNeighbour), fullscreen)

        var scrolledBack = workspace(focused: 2)
        scrolledBack.viewportOffset = focusedOnNeighbour.workspace.viewportOffset
        let focusedBack = try planDisplayLayout(
            workspace: scrolledBack, modes: modes, engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(focusedBack.plan.visible, [id(2): fullscreen])
    }

    func testMovingFocusAmongOtherWindowsNeverResizesTheOffscreenFullscreenWindow() throws {
        let modes: [WindowID: WindowMode] = [id(2): .fullscreen]
        let fullscreenSize = fullscreenFrame(display: display, usable: usable).size
        for focused in [4, 1, 3] as [UInt64] {
            let planned = try planDisplayLayout(
                workspace: workspace(focused: focused), modes: modes, engine: engine,
                viewport: usable, display: display, otherDisplays: []
            )
            XCTAssertEqual(plannedFrame(of: id(2), in: planned)?.size, fullscreenSize, "focused \(focused)")
        }
    }

    func testTogglingFullscreenOffRestoresThePreviousColumnWidth() throws {
        let tiled = try planDisplayLayout(
            workspace: workspace(focused: 4), modes: [:], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        let fullscreen = try planDisplayLayout(
            workspace: workspace(focused: 4), modes: [id(2): .fullscreen], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(fullscreen.workspace.columns, workspace(focused: 4).columns)
        let restored = try planDisplayLayout(
            workspace: fullscreen.workspace, modes: [:], engine: engine,
            viewport: usable, display: display, otherDisplays: []
        )
        XCTAssertEqual(restored.layout.frames[id(2)]?.size, tiled.layout.frames[id(2)]?.size)
        XCTAssertEqual(plannedFrame(of: id(2), in: restored)?.size, plannedFrame(of: id(2), in: tiled)?.size)
    }

    func testPruneDropsRecordsWhoseModeChangedOrWindowVanished() throws {
        let registry = try registry()
        var book = FullscreenBook()
        try book.toggle(id(2), registry: registry, frame: display)
        try book.toggle(id(3), registry: registry, frame: display)
        try book.toggle(id(4), registry: registry, frame: display)
        _ = try registry.toggleFloating(for: id(2))
        registry.remove(id(3))
        book.prune(registry: registry)
        XCTAssertFalse(book.isFullscreen(id(2)))
        XCTAssertFalse(book.isFullscreen(id(3)))
        XCTAssertTrue(book.isFullscreen(id(4)))
        XCTAssertEqual(registry.find(id(4))?.mode, .fullscreen)
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
