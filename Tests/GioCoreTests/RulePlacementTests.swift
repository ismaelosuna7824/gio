import XCTest
@testable import GioCore

/// WR-03..WR-05: where and how a rule-placed window opens (column width,
/// maximized, display, focus), the per-window width limits in the layout,
/// and the one title re-check for windows that appear untitled.
final class RulePlacementTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func column(of window: WindowID, in manager: WorkspaceManager) -> Column? {
        manager.allWorkspaces.flatMap(\.columns).first { $0.windows.contains(window) }
    }

    private func workspaceID(of window: WindowID, in manager: WorkspaceManager) -> WorkspaceID? {
        manager.allWorkspaces.first { $0.columns.contains { $0.windows.contains(window) } }?.id
    }

    // MARK: Column

    func testRuleWidthSetsTheNewColumn() {
        var manager = WorkspaceManager()
        placeArrival(id(1), outcome: RuleOutcome(columnWidth: .points(800)), takesFocus: true, manager: &manager)
        placeArrival(id(2), outcome: RuleOutcome(columnWidth: .proportion(0.33)), takesFocus: true, manager: &manager)
        placeArrival(id(3), outcome: .none, takesFocus: true, manager: &manager)
        XCTAssertEqual(column(of: id(1), in: manager)?.widthSpec, .points(800))
        XCTAssertEqual(column(of: id(2), in: manager)?.widthSpec, .proportion(0.33))
        XCTAssertEqual(column(of: id(3), in: manager)?.widthSpec, .standard)
    }

    // MARK: Popups and dialogs

    func testAPopupOfAnOpenAppIgnoresTheRulesPlacementButTheAppsOnlyWindowKeepsIt() {
        let routed = RuleOutcome(workspace: 2, openOnWorkspace: "Browsers", follow: .always, display: 2)
        for reason in [FloatReason.dialog, .floatingSubrole, .notResizable] {
            let placement = arrivalPlacement(routed, admissionFloat: reason, appHasOtherWindows: true)
            XCTAssertNil(placement.workspace, "\(reason)")
            XCTAssertNil(placement.openOnWorkspace, "\(reason)")
            XCTAssertNil(placement.display, "\(reason)")
            XCTAssertEqual(
                arrivalPlacement(routed, admissionFloat: reason, appHasOtherWindows: false), routed,
                "\(reason): the app's only window is the app"
            )
        }
        XCTAssertEqual(arrivalPlacement(routed, admissionFloat: nil, appHasOtherWindows: true), routed)
        var ruleFloat = routed
        ruleFloat.mode = .floating
        XCTAssertEqual(
            arrivalPlacement(ruleFloat, admissionFloat: .notResizable, appHasOtherWindows: true), ruleFloat,
            "the rule asked for it"
        )
    }

    func testOpenMaximizedIsTheMaximizeToggleState() {
        var manager = WorkspaceManager()
        placeArrival(
            id(1), outcome: RuleOutcome(columnWidth: .proportion(0.5), openMaximized: true), takesFocus: true,
            manager: &manager
        )
        let opened = column(of: id(1), in: manager)!
        XCTAssertEqual(opened.widthSpec, .proportion(1))
        XCTAssertEqual(opened.savedWidthSpec, .proportion(0.5))
        // Alt+F on it restores the rule width.
        let restored = toggleMaximizeFocusedColumn(in: manager.currentWorkspace())
        XCTAssertEqual(restored.columns[0].widthSpec, .proportion(0.5))
        XCTAssertNil(restored.columns[0].savedWidthSpec)

        placeArrival(id(2), outcome: RuleOutcome(openMaximized: true), takesFocus: true, manager: &manager)
        XCTAssertEqual(column(of: id(2), in: manager)?.savedWidthSpec, .standard)
    }

    // MARK: Focus

    func testTakesFocusFollowsTheRuleAndTheWindowState() {
        XCTAssertTrue(arrivalTakesFocus(.none, mode: .tiled, minimized: false))
        XCTAssertFalse(arrivalTakesFocus(RuleOutcome(openFocused: false), mode: .tiled, minimized: false))
        XCTAssertFalse(arrivalTakesFocus(.none, mode: .floating, minimized: false))
        XCTAssertFalse(arrivalTakesFocus(.none, mode: .tiled, minimized: true))
    }

    func testAnUnfocusedArrivalKeepsTheWorkspaceFocus() {
        var manager = WorkspaceManager()
        placeArrival(id(1), outcome: .none, takesFocus: true, manager: &manager)
        placeArrival(id(2), outcome: RuleOutcome(openFocused: false), takesFocus: false, manager: &manager)
        let workspace = manager.currentWorkspace()
        XCTAssertEqual(workspace.columns.map(\.windows), [[id(1)], [id(2)]])
        XCTAssertEqual(workspace.focusedWindow, id(1))
        XCTAssertEqual(workspace.focusedColumn, 0)
    }

    // MARK: Display

    private func twoDisplays(main: DisplayID = DisplayID(1)) -> WorkspaceManager {
        var manager = WorkspaceManager()
        manager.syncDisplays([DisplayID(1), DisplayID(2)], main: main)
        return manager
    }

    func testDisplayNumbersFollowTheWorkspaceDisplayKey() {
        let manager = twoDisplays(main: DisplayID(2))
        XCTAssertEqual(manager.display(numbered: 1), DisplayID(2), "1 is the main display")
        XCTAssertEqual(manager.display(numbered: 2), DisplayID(1))
        XCTAssertNil(manager.display(numbered: 3))
        XCTAssertNil(manager.display(numbered: 0))
    }

    func testOpenOnDisplayUsesThatDisplaysShownWorkspace() {
        var manager = twoDisplays()
        let destination = placeArrival(id(1), outcome: RuleOutcome(display: 2), takesFocus: true, manager: &manager)
        XCTAssertEqual(destination, manager.activeID(on: DisplayID(2)))
        XCTAssertEqual(manager.focusedDisplay, DisplayID(1), "the focused display does not change")
    }

    func testAMissingDisplayFallsBackToTheFocusedOne() {
        var manager = twoDisplays()
        let destination = placeArrival(id(1), outcome: RuleOutcome(display: 5), takesFocus: true, manager: &manager)
        XCTAssertEqual(destination, manager.currentID)
    }

    func testWorkspaceIndexCountsOnTheRuleDisplay() {
        var manager = twoDisplays()
        let destination = placeArrival(
            id(1), outcome: RuleOutcome(workspace: 2, display: 2), takesFocus: true, manager: &manager
        )
        XCTAssertEqual(manager.location(of: destination)?.display, DisplayID(2))
    }

    func testNamedWorkspaceWinsOnlyWhenItLivesOnTheRuleDisplay() {
        var manager = twoDisplays()
        manager.applyNamedWorkspaces([
            WorkspaceDefinition(name: "Code"), WorkspaceDefinition(name: "Chat", display: .index(2)),
        ])
        let chat = manager.namedWorkspaceID("Chat")!
        let code = manager.namedWorkspaceID("Code")!
        XCTAssertEqual(manager.arrivalDestination(RuleOutcome(openOnWorkspace: "Chat", display: 2)), chat)
        XCTAssertNotEqual(manager.arrivalDestination(RuleOutcome(openOnWorkspace: "Code", display: 2)), code)
        XCTAssertEqual(
            manager.arrivalDestination(RuleOutcome(openOnWorkspace: "Code", display: 2)),
            manager.activeID(on: DisplayID(2))
        )
        XCTAssertEqual(manager.arrivalDestination(RuleOutcome(openOnWorkspace: "Code", display: 7)), code)
    }

    // MARK: Width limits in the layout

    private func strip(_ columns: [Column]) -> Workspace {
        Workspace(id: WorkspaceID(1), columns: columns)
    }

    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testLimitsClampTheColumnWidth() throws {
        let engine = ScrollableLayoutEngine(
            config: LayoutConfig(padding: 0, gap: 0, maximizeSingleWindow: false),
            widthLimits: [id(1): ColumnWidthLimits(min: 700, max: nil), id(2): ColumnWidthLimits(min: nil, max: 600)]
        )
        let result = try engine.calculate(workspace: strip([
            Column(id: ColumnID(1), width: 0, windows: [id(1)], widthSpec: .proportion(0.5)),
            Column(id: ColumnID(2), width: 900, windows: [id(2)]),
            Column(id: ColumnID(3), width: 300, windows: [id(3)]),
        ]), viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.width, 700)
        XCTAssertEqual(result.frames[id(2)]?.width, 600)
        XCTAssertEqual(result.frames[id(3)]?.width, 300, "windows without limits are untouched")
    }

    func testTheLearnedMinimumStillWinsOverMaxWidth() throws {
        let engine = ScrollableLayoutEngine(
            config: LayoutConfig(padding: 0, gap: 0, maximizeSingleWindow: false),
            minimumSizes: [id(1): CGSize(width: 800, height: 0)],
            widthLimits: [id(1): ColumnWidthLimits(min: nil, max: 600)]
        )
        let result = try engine.calculate(workspace: strip([
            Column(id: ColumnID(1), width: 500, windows: [id(1)]),
        ]), viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.width, 800)
    }

    func testMinWidthIsCappedToTheViewport() throws {
        let engine = ScrollableLayoutEngine(
            config: LayoutConfig(padding: 10, gap: 0, maximizeSingleWindow: false),
            widthLimits: [id(1): ColumnWidthLimits(min: 5000, max: nil)]
        )
        let result = try engine.calculate(workspace: strip([
            Column(id: ColumnID(1), width: 500, windows: [id(1)]),
        ]), viewport: viewport)
        XCTAssertEqual(result.frames[id(1)]?.width, 980)
    }

    func testStackedWindowsCombineTheirLimits() {
        let combined = ColumnWidthLimits.combined([
            ColumnWidthLimits(min: 400, max: 900), ColumnWidthLimits(min: 500, max: 1200),
        ])
        XCTAssertEqual(combined, ColumnWidthLimits(min: 500, max: 900))
        XCTAssertEqual(ColumnWidthLimits(min: 500, max: 900).clamp(300), 500)
        XCTAssertEqual(ColumnWidthLimits(min: 500, max: 900).clamp(1000), 900)
        XCTAssertEqual(ColumnWidthLimits(min: 950, max: 900).clamp(1000), 950, "min wins a conflict")
    }

    // MARK: Title re-check

    func testRecheckIsArmedOnceForOneSecond() {
        var book = TitleRecheckBook()
        book.arm(id(1), at: 10)
        book.arm(id(2), at: 10)
        XCTAssertFalse(book.take(id(3), now: 10.2), "never armed")
        XCTAssertTrue(book.take(id(1), now: 10.9))
        XCTAssertFalse(book.take(id(1), now: 10.95), "only once")
        XCTAssertFalse(book.take(id(2), now: 11.2), "expired")
        book.arm(id(4), at: 10)
        book.forget(id(4))
        XCTAssertFalse(book.take(id(4), now: 10.1))
    }

    func testRecheckOnlyArmsForUntitledWindowsWhenATitleRuleExists() {
        let titled = [WindowRule(app: "Chrome", title: TitlePattern("Meet"), mode: .floating)]
        XCTAssertTrue(titleRecheckWanted(rules: titled, title: ""))
        XCTAssertFalse(titleRecheckWanted(rules: titled, title: "New Tab"))
        XCTAssertFalse(titleRecheckWanted(rules: [WindowRule(app: "Chrome", mode: .floating)], title: ""))
    }

    private func chromeWindow(_ element: UInt64, title: String) -> ManagedWindow {
        ManagedWindow(
            id: id(element), pid: 10, application: "Chrome", title: title,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), mode: .tiled
        )
    }

    func testRecheckOutcomeOnlyWhenATitleRuleNowWins() {
        let rules = [
            WindowRule(app: "Chrome", title: TitlePattern("Meet"), mode: .floating),
            WindowRule(app: "Chrome", workspace: 2),
        ]
        XCTAssertEqual(titleRecheckOutcome(rules, window: chromeWindow(1, title: "Google Meet"))?.mode, .floating)
        XCTAssertNil(titleRecheckOutcome(rules, window: chromeWindow(1, title: "Inbox")), "same rule as before")
    }

    func testRecheckMovesTheWindowWithoutFocus() throws {
        let registry = WindowRegistry()
        var manager = WorkspaceManager()
        try registry.register(chromeWindow(1, title: "Docs"))
        try registry.register(chromeWindow(2, title: "Standup"))
        placeArrival(id(1), outcome: .none, takesFocus: true, manager: &manager)
        placeArrival(id(2), outcome: .none, takesFocus: true, manager: &manager)
        let start = manager.currentID
        let outcome = RuleOutcome(workspace: 2, columnWidth: .points(640), widthLimits: ColumnWidthLimits(min: 500, max: nil))
        applyTitleRecheck(id(2), outcome: outcome, registry: registry, manager: &manager)
        XCTAssertEqual(manager.currentID, start, "never follows")
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1), "focus stays on the strip")
        XCTAssertEqual(manager.location(of: workspaceID(of: id(2), in: manager)!)?.index, 2)
        XCTAssertEqual(column(of: id(2), in: manager)?.widthSpec, .points(640))
        XCTAssertEqual(registry.find(id(2))?.widthLimits, ColumnWidthLimits(min: 500, max: nil))
    }

    func testRecheckOnTheSameWorkspaceAdjustsTheColumnInPlace() throws {
        let registry = WindowRegistry()
        var manager = WorkspaceManager()
        try registry.register(chromeWindow(1, title: "Meet"))
        placeArrival(id(1), outcome: .none, takesFocus: true, manager: &manager)
        applyTitleRecheck(id(1), outcome: RuleOutcome(openMaximized: true), registry: registry, manager: &manager)
        XCTAssertEqual(manager.currentWorkspace().columns.map(\.windows), [[id(1)]])
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
        XCTAssertEqual(column(of: id(1), in: manager)?.widthSpec, .proportion(1))
    }

    func testRecheckFloatsAndTilesLikeARule() throws {
        let registry = WindowRegistry()
        var manager = WorkspaceManager()
        try registry.register(chromeWindow(1, title: "Meet"))
        placeArrival(id(1), outcome: .none, takesFocus: true, manager: &manager)
        applyTitleRecheck(id(1), outcome: RuleOutcome(mode: .floating), registry: registry, manager: &manager)
        XCTAssertEqual(registry.find(id(1))?.mode, .floating)
        XCTAssertEqual(registry.find(id(1))?.floatReason, .rule)
        applyTitleRecheck(id(1), outcome: RuleOutcome(mode: .tiled), registry: registry, manager: &manager)
        XCTAssertEqual(registry.find(id(1))?.mode, .tiled)
    }

    func testRecheckNeverTilesAnAdmissionFloat() throws {
        let registry = WindowRegistry()
        var manager = WorkspaceManager()
        var dialog = chromeWindow(1, title: "Meet")
        dialog.mode = .floating
        dialog.floatReason = .dialog
        try registry.register(dialog)
        placeArrival(id(1), outcome: .none, takesFocus: false, manager: &manager)
        applyTitleRecheck(id(1), outcome: RuleOutcome(mode: .tiled), registry: registry, manager: &manager)
        XCTAssertEqual(registry.find(id(1))?.floatReason, .dialog)
    }

    // MARK: Pure pipeline

    func testPlaceWindowHonoursTheRichKeys() throws {
        let registry = WindowRegistry()
        var manager = WorkspaceManager()
        try placeWindow(chromeWindow(1, title: "Docs"), rules: [], appKey: "Chrome", registry: registry, manager: &manager)
        let rules = [WindowRule(app: "Chrome", title: TitlePattern("Meet"), columnWidth: .points(700), openFocused: false)]
        try placeWindow(chromeWindow(2, title: "Meet"), rules: rules, appKey: "Chrome", registry: registry, manager: &manager)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
        XCTAssertEqual(column(of: id(2), in: manager)?.widthSpec, .points(700))
    }
}
