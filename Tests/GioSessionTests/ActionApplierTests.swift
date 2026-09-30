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
            .maximizeColumn, .centerColumn, .consumeOrExpelLeft, .consumeOrExpelRight
        ]
        for action in actions {
            switch action {
            case .focusLeft, .focusRight, .focusUp, .focusDown, .moveLeft, .moveRight,
                 .moveColumnLeft, .moveColumnRight, .moveUp, .moveDown, .workspace, .moveToWorkspace,
                 .focusWorkspaceDown, .focusWorkspaceUp, .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp,
                 .toggleFloating, .fullscreen, .switchPresetColumnWidth, .shrinkColumnWidth, .growColumnWidth,
                 .maximizeColumn, .centerColumn, .consumeOrExpelLeft, .consumeOrExpelRight:
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
            .workspace(2), .focusWorkspaceDown, .focusWorkspaceUp, .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp
        ]
        for action in Self.allActions {
            setUp()
            XCTAssertEqual(apply(action).syncsShownWorkspace, syncing.contains(action), "\(action)")
        }
    }

    func testOnlySizingAndCenterReadTheEngineAndOnlyCenterProbesModes() {
        let engineActions: [HotkeyAction] = [
            .switchPresetColumnWidth, .shrinkColumnWidth, .growColumnWidth, .centerColumn
        ]
        for action in Self.allActions {
            setUp()
            apply(action)
            XCTAssertEqual(engineCalls, engineActions.contains(action) ? 1 : 0, "\(action)")
            XCTAssertEqual(modeCalls, action == .centerColumn ? 1 : 0, "\(action)")
            XCTAssertEqual(fallbackCalls, 0, "\(action): a display exists")
        }
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
            (.consumeOrExpelRight, { consumeOrExpelWindow(in: $0, direction: .right) })
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
}
