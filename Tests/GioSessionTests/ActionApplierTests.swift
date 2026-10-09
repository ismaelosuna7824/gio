import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

final class ActionApplierTests: XCTestCase {
    /// Every `HotkeyAction` case; the switch fails to compile when one is added.
    static let allActions: [HotkeyAction] = {
        let actions: [HotkeyAction] = [
            .focusLeft, .focusRight, .focusUp, .focusDown, .moveLeft, .moveRight,
            .moveColumnLeft, .moveColumnRight, .moveUp, .moveDown, .workspace(2), .moveToWorkspace(2),
            .focusWorkspaceDown, .focusWorkspaceUp, .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp,
            .toggleFloating, .fullscreen, .switchPresetColumnWidth, .shrinkColumnWidth, .growColumnWidth,
            .maximizeColumn, .centerColumn, .consumeOrExpelLeft, .consumeOrExpelRight, .toggleOverview,
            .focusMonitor(.right), .moveColumnToMonitor(.right), .moveWindowToMonitor(.right),
            .moveWorkspaceToMonitor(.right),
            .switchPresetWindowHeight, .shrinkWindowHeight, .growWindowHeight, .resetWindowHeight,
            .focusColumnFirst, .focusColumnLast, .moveColumnToFirst, .moveColumnToLast,
            .swapWindowLeft, .swapWindowRight, .moveColumnToWorkspace(2),
            .moveColumnToWorkspaceDown, .moveColumnToWorkspaceUp, .focusWorkspacePrevious,
            .moveWorkspaceDown, .moveWorkspaceUp
        ]
        for action in actions {
            switch action {
            case .focusLeft, .focusRight, .focusUp, .focusDown, .moveLeft, .moveRight,
                 .moveColumnLeft, .moveColumnRight, .moveUp, .moveDown, .workspace, .moveToWorkspace,
                 .focusWorkspaceDown, .focusWorkspaceUp, .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp,
                 .toggleFloating, .fullscreen, .switchPresetColumnWidth, .shrinkColumnWidth, .growColumnWidth,
                 .maximizeColumn, .centerColumn, .consumeOrExpelLeft, .consumeOrExpelRight, .toggleOverview,
                 .focusMonitor, .moveColumnToMonitor, .moveWindowToMonitor, .moveWorkspaceToMonitor,
                 .switchPresetWindowHeight, .shrinkWindowHeight, .growWindowHeight, .resetWindowHeight,
                 .focusColumnFirst, .focusColumnLast, .moveColumnToFirst, .moveColumnToLast,
                 .swapWindowLeft, .swapWindowRight, .moveColumnToWorkspace,
                 .moveColumnToWorkspaceDown, .moveColumnToWorkspaceUp, .focusWorkspacePrevious,
                 .moveWorkspaceDown, .moveWorkspaceUp:
                break
            }
        }
        return actions
    }()

    private var world: ReflowWorld!
    private var ids: [WindowID] = []
    private var engineCalls = 0
    private var modeCalls = 0
    private var fallbackCalls = 0

    override func setUp() {
        world = ReflowWorld()
        ids = world.addColumns(3)
        world.focusColumn(1)
        engineCalls = 0
        modeCalls = 0
        fallbackCalls = 0
    }

    private func context() -> ActionApplier.Context {
        .init(
            registry: world.session.registry, displays: world.displays.allDisplays(),
            visibleFrames: world.visibleFrames, layout: world.session.config.layout,
            engine: {
                self.engineCalls += 1
                return self.world.engine()
            },
            modes: {
                self.modeCalls += 1
                return self.world.modes
            },
            fallbackViewport: {
                self.fallbackCalls += 1
                return CGRect(x: 0, y: 0, width: 1500, height: 900)
            }
        )
    }

    @discardableResult
    private func apply(_ action: HotkeyAction) -> ActionEffect {
        // Like the host: a copy, since the lazy reads touch the session.
        var manager = world.session.manager
        let effect = ActionApplier.apply(action, manager: &manager, context: context())
        world.session.manager = manager
        return effect
    }

    private var current: Workspace {
        world.session.manager.currentWorkspace()
    }

    // MARK: Every case

    func testEveryActionReportsItsFocusIntentSizingAndPreviousFocus() {
        for action in Self.allActions {
            setUp()
            let previous = current.focusedWindow
            let effect = apply(action)
            XCTAssertEqual(effect.carriesFocusIntent, action.carriesFocusIntent, "\(action)")
            XCTAssertEqual(effect.growsFocusedWindow, action.growsFocusedWindow, "\(action)")
            XCTAssertEqual(effect.previousFocus, previous, "\(action)")
        }
    }

    func testOnlyWorkspaceNavigationSyncsTheShownWorkspace() {
        let syncing: [HotkeyAction] = [
            .workspace(2), .focusWorkspaceDown, .focusWorkspaceUp, .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp,
            // One workspace and the spare: the column moves down and is followed;
            // up, previous and the workspace moves have nothing to do.
            .moveColumnToWorkspace(2), .moveColumnToWorkspaceDown
        ]
        for action in Self.allActions {
            setUp()
            XCTAssertEqual(apply(action).syncsShownWorkspace, syncing.contains(action), "\(action)")
        }
    }

    func testOnlySizingAndCenterReadTheEngineAndOnlyCenterProbesModes() {
        let engineActions: [HotkeyAction] = [
            .switchPresetColumnWidth, .shrinkColumnWidth, .growColumnWidth, .centerColumn,
            .switchPresetWindowHeight, .shrinkWindowHeight, .growWindowHeight
        ]
        for action in Self.allActions {
            setUp()
            apply(action)
            XCTAssertEqual(engineCalls, engineActions.contains(action) ? 1 : 0, "\(action)")
            XCTAssertEqual(modeCalls, action == .centerColumn ? 1 : 0, "\(action)")
            XCTAssertEqual(fallbackCalls, 0, "\(action): a display exists")
        }
    }

    func testOverviewLeavesTheSessionUntouched() {
        let before = world.session.manager
        let effect = apply(.toggleOverview)
        XCTAssertEqual(world.session.manager, before)
        XCTAssertFalse(effect.carriesFocusIntent)
        XCTAssertNil(effect.zoomRequest)
        XCTAssertNil(effect.fullscreenToggle)
    }

    // MARK: Focus and moves

    func testFocusMovesMatchCoreAndNoOpsLeaveTheManagerAlone() {
        for (action, direction) in [
            (HotkeyAction.focusLeft, FocusDirection.left), (.focusRight, .right), (.focusUp, .up), (.focusDown, .down)
        ] {
            setUp()
            let expected = moveFocus(in: current, direction: direction)
            apply(action)
            XCTAssertEqual(current, expected, "\(action)")
        }
        for (action, core) in [
            (HotkeyAction.focusColumnFirst, focusColumnFirst(in:)), (.focusColumnLast, focusColumnLast(in:))
        ] {
            setUp()
            let expected = core(current)
            XCTAssertNotEqual(expected, current, "\(action)")
            apply(action)
            XCTAssertEqual(current, expected, "\(action)")
        }
        world.focusColumn(0)
        let before = world.session.manager
        apply(.focusLeft)
        XCTAssertEqual(world.session.manager, before)
    }

    func testMoveColumnAndLegacyMoveMatchCore() {
        let cases: [(HotkeyAction, (Workspace) -> Workspace)] = [
            (.moveColumnLeft, { moveColumn(in: $0, direction: .left) }),
            (.moveColumnRight, { moveColumn(in: $0, direction: .right) }),
            (.moveLeft, { moveWindow(in: $0, direction: .left) }),
            (.moveRight, { moveWindow(in: $0, direction: .right) }),
            (.moveUp, { moveWindow(in: $0, direction: .up) }),
            (.moveDown, { moveWindow(in: $0, direction: .down) }),
            (.consumeOrExpelLeft, { consumeOrExpelWindow(in: $0, direction: .left) }),
            (.consumeOrExpelRight, { consumeOrExpelWindow(in: $0, direction: .right) }),
            (.moveColumnToFirst, { moveColumnToFirst(in: $0) }),
            (.moveColumnToLast, { moveColumnToLast(in: $0) }),
            (.swapWindowLeft, { swapWindow(in: $0, direction: .left) }),
            (.swapWindowRight, { swapWindow(in: $0, direction: .right) })
        ]
        for (action, core) in cases {
            setUp()
            let expected = core(current)
            apply(action)
            XCTAssertEqual(current, expected, "\(action)")
        }
    }

    func testConsumeThenExpelRoundTrips() {
        apply(.consumeOrExpelLeft)
        XCTAssertEqual(current.columns.count, 2)
        XCTAssertEqual(current.columns[0].windows, [ids[0], ids[1]])
        apply(.consumeOrExpelRight)
        XCTAssertEqual(current.columns.count, 3)
    }

    // MARK: Workspaces

    func testWorkspaceSwitchAndMoves() {
        apply(.workspace(2))
        XCTAssertEqual(world.session.manager.current, 2)
        setUp()
        apply(.moveToWorkspace(2))
        XCTAssertFalse(current.columns.flatMap(\.windows).contains(ids[1]))
        XCTAssertEqual(world.session.manager.workspace(2)?.columns.flatMap(\.windows), [ids[1]])
        setUp()
        apply(.moveWindowToWorkspaceDown)
        XCTAssertEqual(world.session.manager.workspace(2)?.columns.flatMap(\.windows), [ids[1]])
        XCTAssertEqual(world.session.manager.current, 2, "the window follows")
        apply(.focusWorkspaceUp)
        XCTAssertEqual(world.session.manager.current, 1)
        apply(.focusWorkspaceDown)
        XCTAssertEqual(world.session.manager.current, 2)
        apply(.moveWindowToWorkspaceUp)
        XCTAssertEqual(world.session.manager.current, 1)
        XCTAssertTrue(current.columns.flatMap(\.windows).contains(ids[1]))
    }

    func testColumnToWorkspaceActionsMatchTheManagerAndFollow() {
        let cases: [(HotkeyAction, (inout WorkspaceManager) -> Bool)] = [
            (.moveColumnToWorkspace(2), { $0.moveColumn(toWorkspace: 2) }),
            (.moveColumnToWorkspaceDown, { $0.moveColumnToWorkspaceDown() }),
        ]
        for (action, move) in cases {
            setUp()
            var expected = world.session.manager
            XCTAssertTrue(move(&expected), "\(action)")
            let effect = apply(action)
            XCTAssertEqual(world.session.manager, expected, "\(action)")
            XCTAssertEqual(world.session.manager.current, 2, "\(action): focus follows the column")
            XCTAssertEqual(current.focusedWindow, ids[1], "\(action)")
            XCTAssertTrue(effect.syncsShownWorkspace, "\(action)")
            XCTAssertTrue(effect.carriesFocusIntent, "\(action)")
        }
        let back = apply(.moveColumnToWorkspaceUp)
        XCTAssertEqual(world.session.manager.current, 1)
        XCTAssertEqual(current.focusedWindow, ids[1])
        XCTAssertEqual(current.columns.count, 3)
        XCTAssertTrue(back.syncsShownWorkspace)
    }

    func testFocusWorkspacePreviousAndMoveWorkspaceMatchTheManager() {
        apply(.moveColumnToWorkspaceDown)
        var expected = world.session.manager
        XCTAssertTrue(expected.focusWorkspacePrevious())
        let previous = apply(.focusWorkspacePrevious)
        XCTAssertEqual(world.session.manager, expected)
        XCTAssertEqual(world.session.manager.current, 1)
        XCTAssertTrue(previous.syncsShownWorkspace)
        XCTAssertTrue(previous.carriesFocusIntent)

        let shown = world.session.manager.currentID
        let moved = apply(.moveWorkspaceDown)
        XCTAssertEqual(world.session.manager.currentID, shown, "the same workspace stays shown")
        XCTAssertEqual(world.session.manager.current, 2)
        XCTAssertFalse(moved.syncsShownWorkspace, "nothing to show differently")
        XCTAssertFalse(moved.carriesFocusIntent)
        apply(.moveWorkspaceUp)
        XCTAssertEqual(world.session.manager.current, 1)
    }

    func testMoveWorkspaceRefusesANamedWorkspaceAndLogsIt() {
        world.session.manager.applyNamedWorkspaces([WorkspaceDefinition(name: "Code")])
        XCTAssertTrue(world.session.manager.focus(world.session.manager.namedWorkspaceID("Code")!))
        let before = world.session.manager
        apply(.moveWorkspaceDown)
        XCTAssertEqual(world.session.manager, before)
        let id = before.currentID.rawValue
        XCTAssertTrue(GioLog.entries().contains {
            $0.message == "move-workspace-down refused: workspace \(id) is named; config order places it"
        })
        XCTAssertFalse(GioLog.entries().contains { $0.message.contains("Code") }, "no names in the log")
    }

    func testWindowMovesWithoutFocusDoNothingAndDoNotSync() {
        var workspace = current
        workspace.focusedWindow = nil
        world.session.manager.update(workspace)
        let before = world.session.manager
        for action in [HotkeyAction.moveToWorkspace(2), .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp] {
            let effect = apply(action)
            XCTAssertEqual(world.session.manager, before, "\(action)")
            XCTAssertFalse(effect.syncsShownWorkspace, "\(action)")
        }
        XCTAssertNil(apply(.fullscreen).fullscreenToggle)
        apply(.toggleFloating)
        XCTAssertEqual(world.session.registry.find(ids[1])?.mode, .tiled)
    }

    // MARK: Floating, fullscreen, sizing

    func testToggleFloatingFlipsTheRegistry() {
        apply(.toggleFloating)
        XCTAssertEqual(world.session.registry.find(ids[1])?.mode, .floating)
        apply(.toggleFloating)
        XCTAssertEqual(world.session.registry.find(ids[1])?.mode, .tiled)
    }

    func testFullscreenAsksTheHostToToggleWithTheDisplayFrame() {
        world.session.config.layout.fullscreenGap = 8
        let effect = apply(.fullscreen)
        let expected = fullscreenFrame(
            display: ReflowWorld.leftFrame, usable: world.visibleFrames[ReflowWorld.left]!, gap: 8
        )
        XCTAssertEqual(effect.fullscreenToggle, .init(id: ids[1], frame: expected))
        XCTAssertEqual(world.session.registry.find(ids[1])?.mode, .tiled, "the host's book flips it")
    }

    func testMaximizeHandsThePreToggleWorkspaceToNativeZoom() {
        let before = current
        let effect = apply(.maximizeColumn)
        XCTAssertEqual(effect.zoomRequest, before)
        XCTAssertEqual(current, toggleMaximizeFocusedColumn(in: before))
        XCTAssertNotNil(current.columns[1].savedWidthSpec)
        let maximized = current
        let restore = apply(.maximizeColumn)
        XCTAssertEqual(restore.zoomRequest, maximized)
        XCTAssertNil(current.columns[1].savedWidthSpec, "restored")
        XCTAssertTrue(effect.growsFocusedWindow)
    }

    func testWidthActionsResolveAgainstTheFocusedDisplaysUsableWidth() {
        let width = world.visibleFrames[ReflowWorld.left]!.width
        let config = world.engine().config
        let before = current
        apply(.switchPresetColumnWidth)
        XCTAssertEqual(current, switchPresetColumnWidth(
            in: before, presets: world.session.config.layout.presetColumnWidths, config: config, viewportWidth: width
        ))
        for (action, step) in [(HotkeyAction.growColumnWidth, CGFloat(0.1)), (.shrinkColumnWidth, -0.1)] {
            setUp()
            let start = current
            apply(action)
            XCTAssertEqual(current, stepFocusedColumnWidth(in: start, by: step, config: config, viewportWidth: width))
        }
    }

    func testHeightActionsResolveAgainstTheFocusedDisplaysUsableHeight() {
        apply(.consumeOrExpelLeft)
        XCTAssertEqual(current.columns[0].windows.count, 2, "a stacked column")
        let height = world.visibleFrames[ReflowWorld.left]!.height
        let config = world.engine().config
        let presets = world.session.config.layout.presetWindowHeights
        let cases: [(HotkeyAction, (Workspace) -> Workspace)] = [
            (.switchPresetWindowHeight, {
                switchPresetWindowHeight(in: $0, presets: presets, config: config, viewportHeight: height)
            }),
            (.growWindowHeight, { stepFocusedWindowHeight(in: $0, by: 0.1, config: config, viewportHeight: height) }),
            (.shrinkWindowHeight, { stepFocusedWindowHeight(in: $0, by: -0.1, config: config, viewportHeight: height) }),
        ]
        for (action, core) in cases {
            let start = current
            let expected = core(start)
            XCTAssertNotEqual(expected, start, "\(action)")
            let effect = apply(action)
            XCTAssertEqual(current, expected, "\(action)")
            XCTAssertTrue(effect.growsFocusedWindow, "\(action)")
        }
        XCTAssertFalse(current.columns[0].heightWeights.isEmpty)
        apply(.resetWindowHeight)
        XCTAssertEqual(current.columns[0].heightWeights, [:])
    }

    func testCenterColumnMatchesCore() {
        world.addColumns(3, pidBase: 200)
        world.focusColumn(2)
        let before = current
        apply(.centerColumn)
        XCTAssertEqual(current, centerFocusedColumn(
            in: before, modes: world.modes, engine: world.engine(),
            viewport: world.visibleFrames[ReflowWorld.left]!
        ))
    }

    func testWithoutDisplaysTheMainScreenIsTheViewport() {
        world.displays.disconnect(ReflowWorld.left)
        XCTAssertEqual(
            ActionApplier.focusedViewport(manager: world.session.manager, context: context()),
            CGRect(x: 0, y: 0, width: 1500, height: 900)
        )
        XCTAssertNil(apply(.fullscreen).fullscreenToggle, "no display, no fullscreen")
    }

    func testAWorkspaceNoDisplayShowsYetResolvesOnTheFocusedDisplay() {
        // MM-01: between a switch and the next `syncShownWorkspace`, the
        // current workspace is on no display; the focused display, not the
        // first one, is where it is about to show.
        world = ReflowWorld(twoDisplays: true)
        world.addColumns(2, on: ReflowWorld.right)
        let manager = world.session.manager
        XCTAssertTrue(world.session.manager.focus(manager.activeID(on: ReflowWorld.right)!))
        world.session.manager.switchTo(2)
        XCTAssertFalse(world.displays.allDisplays().contains { $0.workspace == world.session.manager.currentID })
        XCTAssertEqual(
            ActionApplier.focusedViewport(manager: world.session.manager, context: context()),
            world.visibleFrames[ReflowWorld.right]
        )
    }

    // MARK: Monitors (MM-02)

    private static let directions: [FocusDirection] = [.left, .right, .up, .down]
    private static let monitorActions: [@Sendable (FocusDirection) -> HotkeyAction] = [
        { .focusMonitor($0) }, { .moveColumnToMonitor($0) },
        { .moveWindowToMonitor($0) }, { .moveWorkspaceToMonitor($0) },
    ]

    /// The left display (focused) with three columns, the right one empty.
    private func twoDisplays() {
        world = ReflowWorld(twoDisplays: true)
        ids = world.addColumns(3)
        world.focusColumn(1)
    }

    func testMonitorActionsWithoutANeighbourLeaveTheManagerAlone() {
        for make in Self.monitorActions {
            for direction in Self.directions {
                setUp()
                let before = world.session.manager
                let effect = apply(make(direction))
                XCTAssertEqual(world.session.manager, before, "\(make(direction)): one display")
                XCTAssertFalse(effect.syncsShownWorkspace, "\(make(direction))")
                XCTAssertNil(effect.warpsToDisplay, "\(make(direction))")
            }
            for direction in [FocusDirection.left, .up, .down] {
                twoDisplays()
                let before = world.session.manager
                let effect = apply(make(direction))
                XCTAssertEqual(world.session.manager, before, "\(make(direction)): nothing that way")
                XCTAssertFalse(effect.syncsShownWorkspace, "\(make(direction))")
            }
        }
    }

    func testFocusMonitorGoesToTheNeighbourAndAnEmptyOneTakesTheCursor() {
        twoDisplays()
        let before = world.session.manager
        let effect = apply(.focusMonitor(.right))
        XCTAssertEqual(world.session.manager.focusedDisplay, ReflowWorld.right)
        XCTAssertEqual(world.session.manager.currentID, before.activeID(on: ReflowWorld.right))
        XCTAssertTrue(effect.syncsShownWorkspace)
        XCTAssertTrue(effect.carriesFocusIntent)
        XCTAssertEqual(
            effect.warpsToDisplay, world.visibleFrames[ReflowWorld.right],
            "no window to focus there: mouse-follows-focus takes the cursor to the display"
        )

        let back = apply(.focusMonitor(.left))
        XCTAssertEqual(world.session.manager.focusedDisplay, ReflowWorld.left)
        XCTAssertEqual(current.focusedWindow, ids[1])
        XCTAssertNil(back.warpsToDisplay, "the focused window takes the cursor")
    }

    func testMovesToMonitorMatchCoreAndFocusFollows() {
        let cases: [((FocusDirection) -> HotkeyAction, (inout WorkspaceManager) -> Bool)] = [
            (HotkeyAction.moveColumnToMonitor, { $0.moveColumn(toDisplay: ReflowWorld.right) }),
            (HotkeyAction.moveWindowToMonitor, { $0.moveWindow(toDisplay: ReflowWorld.right) }),
            (HotkeyAction.moveWorkspaceToMonitor, { $0.moveWorkspace(toDisplay: ReflowWorld.right) }),
        ]
        for (make, move) in cases {
            twoDisplays()
            var expected = world.session.manager
            XCTAssertTrue(move(&expected), "\(make(.right))")
            let effect = apply(make(.right))
            XCTAssertEqual(world.session.manager, expected, "\(make(.right))")
            XCTAssertEqual(world.session.manager.focusedDisplay, ReflowWorld.right, "\(make(.right))")
            XCTAssertEqual(current.focusedWindow, ids[1], "\(make(.right)): the moved window keeps focus")
            XCTAssertTrue(effect.syncsShownWorkspace, "\(make(.right))")
            XCTAssertTrue(effect.carriesFocusIntent, "\(make(.right))")
            XCTAssertNil(effect.warpsToDisplay, "\(make(.right))")
        }
    }
}
