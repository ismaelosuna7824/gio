@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

final class FocusCoordinatorTests: XCTestCase {
    /// Host state behind the focus context. Elements are real (application)
    /// AX elements used as opaque handles; nothing is read from them.
    private final class World: @unchecked Sendable {
        var shuttingDown = false
        var mouseDown = false
        var mouseLocation = CGPoint(x: 5000, y: 5000)
        var frontmost: pid_t?
        var known: [(AXUIElement, WindowID)] = []
        var focusedElements: [pid_t: AXUIElement] = [:]
        var focusedElementReads: [pid_t] = []
        var frames: [WindowID: CGRect] = [:]
        var minimized: Set<WindowID> = []
        var registered: [pid_t] = []
        var scroll: (from: CGFloat, to: CGFloat)?
        var topPID: pid_t?
        var topLookups = 0
        var clickOnSystemUI = false
        var warps: [CGPoint] = []
        var mouseFollowsFocus = true
        var centerMode = CenterFocusedColumnMode.never
        var ringPublishes = 0
        var reflows = 0
        var shownWorkspaces: [WorkspaceID] = []
        var revealCauses: [MotionCause] = []
        var windowWorkAllowed = true
        var logs: [(LogLevel, String)] = []

        func id(of element: AXUIElement) -> WindowID? {
            known.first { CFEqual($0.0, element) }?.1
        }
    }

    private static let ownPID: pid_t = 999
    private static let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    private let frames = [
        CGRect(x: 0, y: 100, width: 500, height: 800),
        CGRect(x: 600, y: 100, width: 500, height: 800),
        CGRect(x: 1200, y: 100, width: 500, height: 800),
    ]
    private var world: World!
    private var fixture: SessionFixture!
    private var scheduler: ManualScheduler!
    private var focus: FocusCoordinator!
    /// Window 1 and 2 share pid 2 (same-app drift); window 0 is pid 1.
    private var ids: [WindowID] = []

    override func setUp() {
        world = World()
        scheduler = ManualScheduler()
        fixture = SessionFixture(frames: frames, focus: 0, pid: { $0 == 0 ? 1 : 2 })
        ids = (0..<3).map { SessionFixture.id($0, pid: $0 == 0 ? 1 : 2) }
        for (index, id) in ids.enumerated() {
            let element = AXUIElementCreateApplication(pid_t(100 + index))
            world.known.append((element, id))
            world.frames[id] = frames[index]
        }
        focus = makeCoordinator(ownPID: Self.ownPID)
    }

    private func makeCoordinator(ownPID: pid_t) -> FocusCoordinator {
        let world = world!
        let fixture = fixture!
        let scheduler = scheduler!
        return FocusCoordinator(
            context: .init(
                isShuttingDown: { world.shuttingDown },
                isMouseDown: { world.mouseDown },
                mouseLocation: { world.mouseLocation },
                frontmostPID: { world.frontmost },
                ownPID: ownPID,
                windowAreas: { [Self.screen] },
                currentWorkspace: { fixture.session.manager.currentWorkspace() },
                updateWorkspace: { fixture.session.manager.update($0) },
                isMinimized: { world.minimized.contains($0) },
                knownWindow: { element, _ in world.id(of: element) },
                focusedWindowElement: { pid in
                    world.focusedElementReads.append(pid)
                    return world.focusedElements[pid]
                },
                frame: { world.frames[$0] },
                registerAppeared: { _, pid in world.registered.append(pid) },
                pendingScroll: { world.scroll },
                isVisibleInViewport: { _ in true },
                topWindowOwnerPID: { _ in
                    world.topLookups += 1
                    return world.topPID
                },
                warpCursor: { world.warps.append($0) },
                clickOnSystemUI: { _ in world.clickOnSystemUI },
                mouseFollowsFocus: { world.mouseFollowsFocus },
                centerMode: { world.centerMode },
                publishFocusRing: { world.ringPublishes += 1 },
                reflowAll: { world.reflows += 1 },
                workspaceFocusPlan: { planFocusWindow($0, in: fixture.session.manager) },
                showWorkspace: { workspace, cause in
                    world.shownWorkspaces.append(workspace)
                    world.revealCauses.append(cause)
                    _ = fixture.session.manager.focus(workspace)
                },
                log: { world.logs.append(($0, $1)) },
                now: { scheduler.now },
                allowsWindowWork: { world.windowWorkAllowed }
            ),
            scheduler: scheduler
        )
    }

    private func element(_ index: Int) -> AXUIElement {
        world.known[index].0
    }

    private func center(_ index: Int) -> CGPoint {
        CGPoint(x: frames[index].midX, y: frames[index].midY)
    }

    private var focused: WindowID? {
        fixture.focusedID
    }

    private func focusLogically(_ index: Int) {
        var workspace = fixture.session.manager.currentWorkspace()
        workspace.focusedColumn = index
        workspace.focusedWindow = ids[index]
        fixture.session.manager.update(workspace)
    }

    private func plans(_ index: Int) -> [ParkingPlan] {
        [ParkingPlan(visible: [ids[index]: frames[index]])]
    }

    // MARK: Own pid

    func testOwnPidIsNeverAdoptedNorRead() {
        world.frontmost = Self.ownPID
        world.focusedElements[Self.ownPID] = element(1)

        focus.requestAdoption(.activation, pid: Self.ownPID, element: nil)
        focus.requestAdoption(.focusChanged, pid: Self.ownPID, element: element(1))
        scheduler.advance(by: 1)

        XCTAssertEqual(focused, ids[0])
        XCTAssertTrue(world.focusedElementReads.isEmpty)
        XCTAssertTrue(world.registered.isEmpty)
    }

    func testReassertNeverReadsOwnPidsFocusedWindow() {
        // The intent target's pid is (made) Gio's own: the drift check must
        // not read it and falls back to the user's intent (unreadable).
        focus = makeCoordinator(ownPID: 2)
        focusLogically(1)
        focus.requestIntent(if: true, previous: ids[0])
        focus.focusAtMotionStart(parked: [], plans: plans(1)) { _ in }
        world.frontmost = 2

        let settle = focus.takeSettleFocus(parked: [])

        XCTAssertEqual(settle.target, ids[1])
        XCTAssertTrue(world.focusedElementReads.isEmpty)
        XCTAssertTrue(world.logs.contains { $0.1.contains("focus reassert id=2:2 reason=unreadable") })
    }

    func testHoverNeverTargetsWhenGioOwnsTheTopWindow() {
        focus.focusFollowsMouse = true
        focus.setHoverFrames([ids[1]: frames[1]])
        world.topPID = Self.ownPID
        world.mouseLocation = center(1)

        focus.pointerMoved(center(1))
        scheduler.advance(by: 1)

        XCTAssertEqual(focused, ids[0])
        XCTAssertEqual(world.reflows, 0)
    }

    // MARK: Foreign Space

    func testForeignSpaceAdoptsAndRegistersNothing() {
        world.windowWorkAllowed = false
        world.frontmost = 2
        world.focusedElements[2] = element(1)
        let stranger = AXUIElementCreateApplication(777)
        world.focusedElements[3] = stranger
        world.frontmost = 3

        focus.requestAdoption(.activation, pid: 3, element: nil)
        focus.requestAdoption(.focusChanged, pid: 3, element: stranger)
        scheduler.advance(by: 1)

        XCTAssertEqual(focused, ids[0])
        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertEqual(world.reflows, 0)
        XCTAssertTrue(world.focusedElementReads.isEmpty)
    }

    func testDirectAdoptionIsRefusedOnAForeignSpace() {
        world.windowWorkAllowed = false

        XCTAssertFalse(focus.adoptFocus(ids[1], source: .rescan))

        XCTAssertEqual(focused, ids[0])
    }

    func testDiscardedPendingClickAdoptionNeverResolves() {
        world.frontmost = 2
        world.focusedElements[2] = element(1)
        world.mouseLocation = center(1)
        focus.recordClick(at: center(1))
        focus.requestAdoption(.focusChanged, pid: 2, element: element(1))

        focus.discardPendingAdoptions()
        scheduler.advance(by: 2)

        XCTAssertEqual(focused, ids[0])
        XCTAssertTrue(world.focusedElementReads.isEmpty)
    }

    func testAdoptionResumesOnceTheManagedSpaceIsBack() {
        world.windowWorkAllowed = false
        world.frontmost = 2
        world.focusedElements[2] = element(1)
        focus.requestAdoption(.focusChanged, pid: 2, element: element(1))
        XCTAssertEqual(focused, ids[0])

        world.windowWorkAllowed = true
        focus.requestAdoption(.focusChanged, pid: 2, element: element(1))

        XCTAssertEqual(focused, ids[1])
    }

    // MARK: Adoption

    func testKeyboardActivationAdoptsAtOnceAndReflowsOnlyToScroll() {
        world.frontmost = 2
        world.focusedElements[2] = element(1)

        focus.requestAdoption(.activation, pid: 2, element: nil)

        XCTAssertEqual(focused, ids[1])
        XCTAssertEqual(world.ringPublishes, 1)
        XCTAssertEqual(world.reflows, 0)

        world.scroll = (0, 600)
        world.focusedElements[1] = element(0)
        world.frontmost = 1
        focus.requestAdoption(.activation, pid: 1, element: nil)
        XCTAssertEqual(focused, ids[0])
        XCTAssertEqual(world.reflows, 1)
        XCTAssertTrue(world.logs.contains { $0.1.contains("scroll=0->600") })
    }

    private func moveToHiddenWorkspace(_ index: Int) {
        _ = fixture.session.manager.moveWindow(ids[index], to: 2)
    }

    func testFocusChangedOnAHiddenWorkspaceWindowSwitchesAndRevealsWithoutFocusCall() {
        moveToHiddenWorkspace(2)
        world.frontmost = 2
        let hiddenWorkspace = fixture.session.manager.workspace(2)!.id

        focus.requestAdoption(.focusChanged, pid: 2, element: element(2))

        XCTAssertEqual(world.shownWorkspaces, [hiddenWorkspace])
        XCTAssertEqual(world.revealCauses, [.workspaceSwitch])
        XCTAssertEqual(fixture.session.manager.current, 2)
        XCTAssertEqual(focused, ids[2])
        XCTAssertEqual(world.reflows, 1)
        XCTAssertTrue(world.logs.contains {
            $0.0 == .info && $0.1 == "focus reveal id=2:3 workspace=2 source=focusChanged"
        })
        let settle = focus.takeSettleFocus(parked: [])
        XCTAssertNil(settle.target)
    }

    /// WC-13: live (2026-10-15, auto-hidden Dock): clicking an app in the
    /// Dock activated it, but the click was inside the usable area (the
    /// Dock hides), so it counted as a window click and the parked window
    /// on another workspace was dropped (`focused window not under click`).
    /// A click on the Dock or the menu bar (the frontmost window under it,
    /// Gio's own aside, is above the normal layers) explains no focus: the
    /// activation reveals the app's window on its workspace.
    func testADockClickRevealsTheActivatedAppsWindowOnItsWorkspace() {
        moveToHiddenWorkspace(2)
        world.clickOnSystemUI = true
        focus.recordClick(at: CGPoint(x: 900, y: 40))
        scheduler.runPending()
        XCTAssertNil(focus.currentClick(), "the Dock is not a window")

        world.frontmost = 2
        world.focusedElements[2] = element(2)
        focus.requestAdoption(.activation, pid: 2, element: nil)
        scheduler.advance(by: 1)

        XCTAssertEqual(fixture.session.manager.current, 2)
        XCTAssertEqual(focused, ids[2])
        XCTAssertTrue(world.logs.contains { $0.1 == "focus reveal id=2:3 workspace=2 source=activation" })
    }

    func testRevealOnAnotherDisplaysShownWorkspaceIsNotAWorkspaceSwitch() {
        // MM-01: the window's workspace is already on screen on display 2;
        // only the focused display changes, so nothing slides.
        let other = DisplayID(2)
        fixture.session.manager.syncDisplays([SessionFixture.display, other])
        var current = fixture.session.manager.currentWorkspace()
        current.stripWindows([ids[2]])
        fixture.session.manager.update(current)
        let shownOnOther = fixture.session.manager.activeID(on: other)!
        var target = fixture.session.manager.workspace(id: shownOnOther)!
        target.columns = [Column(id: ColumnID(1), width: 0, windows: [ids[2]])]
        fixture.session.manager.update(target)
        world.frontmost = 2

        focus.requestAdoption(.focusChanged, pid: 2, element: element(2))

        XCTAssertEqual(world.shownWorkspaces, [shownOnOther])
        XCTAssertEqual(world.revealCauses, [.passive])
        XCTAssertEqual(fixture.session.manager.focusedDisplay, other)
        XCTAssertEqual(focused, ids[2])
    }

    func testActivationRevealsTheAppsFocusedWindowNotTheFirstOfItsPid() {
        moveToHiddenWorkspace(2)
        world.frontmost = 2
        world.focusedElements[2] = element(2)

        focus.requestAdoption(.activation, pid: 2, element: nil)

        XCTAssertEqual(fixture.session.manager.current, 2)
        XCTAssertEqual(focused, ids[2])
        XCTAssertTrue(world.logs.contains { $0.1.hasSuffix("source=activation") })
    }

    func testSameAppWindowOnTheCurrentWorkspaceDoesNotSwitch() {
        moveToHiddenWorkspace(2)
        world.frontmost = 2

        focus.requestAdoption(.focusChanged, pid: 2, element: element(1))

        XCTAssertEqual(world.shownWorkspaces, [])
        XCTAssertEqual(fixture.session.manager.current, 1)
        XCTAssertEqual(focused, ids[1])
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("focus reveal") })
    }

    func testRevealCancelsAStaleKeyboardIntent() {
        moveToHiddenWorkspace(2)
        focus.requestIntent(if: true, previous: nil)
        scheduler.advance(by: FocusIntent.requestWindow + 1)
        world.frontmost = 2

        focus.requestAdoption(.focusChanged, pid: 2, element: element(2))

        XCTAssertNil(focus.takeSettleFocus(parked: []).target)
    }

    func testRevealIsRefusedOnAForeignSpace() {
        moveToHiddenWorkspace(2)
        world.frontmost = 2
        world.windowWorkAllowed = false

        focus.requestAdoption(.focusChanged, pid: 2, element: element(2))

        XCTAssertEqual(world.shownWorkspaces, [])
        XCTAssertEqual(fixture.session.manager.current, 1)
    }

    func testMinimizedWindowOnAHiddenWorkspaceIsNotRevealed() {
        moveToHiddenWorkspace(2)
        world.frontmost = 2
        world.minimized = [ids[2]]

        focus.requestAdoption(.focusChanged, pid: 2, element: element(2))

        XCTAssertEqual(world.shownWorkspaces, [])
    }

    func testBackgroundAppKeyWindowChangeIsIgnored() {
        world.frontmost = 1
        focus.requestAdoption(.focusChanged, pid: 2, element: element(1))

        XCTAssertEqual(focused, ids[0])
    }

    func testMinimizedOrUnknownWindows() {
        world.frontmost = 2
        world.minimized = [ids[1]]
        focus.requestAdoption(.focusChanged, pid: 2, element: element(1))
        XCTAssertEqual(focused, ids[0])

        let stranger = AXUIElementCreateApplication(4242)
        focus.requestAdoption(.focusChanged, pid: 2, element: stranger)
        XCTAssertEqual(world.registered, [2], "unknown windows go to single-window admission")
    }

    func testClickSettlesAfterReleaseAndMatchesTheClickPoint() {
        world.frontmost = 2
        world.focusedElements[2] = element(1)
        world.mouseDown = true
        focus.recordClick(at: center(1))

        focus.requestAdoption(.activation, pid: 2, element: nil)
        focus.requestAdoption(.focusChanged, pid: 2, element: element(1))
        scheduler.advance(by: 0.5)
        XCTAssertEqual(focused, ids[0], "nothing while the button is down")

        world.mouseDown = false
        scheduler.advance(by: 0.05)
        XCTAssertEqual(focused, ids[0], "settle delay after release")
        scheduler.advance(by: 0.1)
        XCTAssertEqual(focused, ids[1])
        XCTAssertEqual(world.ringPublishes, 1, "the two events of one click adopt once")
    }

    func testClickNotOnTheFocusedWindowIsReReadOnceThenDropped() {
        world.frontmost = 2
        world.focusedElements[2] = element(1)
        focus.recordClick(at: center(2))

        focus.requestAdoption(.activation, pid: 2, element: nil)
        scheduler.advance(by: 0.15)
        XCTAssertEqual(focused, ids[0])
        let reads = world.focusedElementReads.count

        scheduler.advance(by: 0.2)
        XCTAssertEqual(world.focusedElementReads.count, reads + 1, "one fresh re-read")
        XCTAssertEqual(focused, ids[0])
        let dropped = world.logs.map(\.1).filter { $0.hasPrefix("focus dropped") }
        XCTAssertEqual(dropped.count, 1)
        XCTAssertTrue(dropped[0].contains("id=2:2"))
        XCTAssertFalse(world.logs.contains { $0.1.contains("secret title") })
    }

    func testClickReReadAdoptsTheWindowTheAppFocusedMeanwhile() {
        world.frontmost = 2
        world.focusedElements[2] = element(1)
        focus.recordClick(at: center(2))
        focus.requestAdoption(.activation, pid: 2, element: nil)
        scheduler.advance(by: 0.15)

        world.focusedElements[2] = element(2)
        scheduler.advance(by: 0.2)

        XCTAssertEqual(focused, ids[2])
    }

    func testClickOutsideEveryWindowAreaIsNoClick() {
        focus.recordClick(at: CGPoint(x: 10, y: 1160))
        XCTAssertNil(focus.currentClick())
        focus.recordClick(at: center(0))
        XCTAssertEqual(focus.currentClick()?.location, center(0))
        scheduler.advance(by: 0.5)
        XCTAssertNil(focus.currentClick(), "a click only explains focus moments after it")
    }

    // MARK: Keyboard intent

    func testIntentFocusesAtMotionStartWarpsAndReassertsSameAppDrift() {
        focusLogically(1)
        focus.requestIntent(if: true, previous: ids[0])
        XCTAssertEqual(focus.pendingIntentTarget(parked: []), ids[1])
        XCTAssertNil(focus.pendingIntentTarget(parked: [ids[1]]))

        var raised: [WindowID] = []
        // PF-Q: the closure only hands the focus off (the reconciler runs it
        // on its own queue); nothing waits for its result here.
        focus.focusAtMotionStart(parked: [], plans: plans(1)) {
            raised.append($0)
        }
        XCTAssertEqual(raised, [ids[1]])
        XCTAssertTrue(world.logs.contains { $0.1 == "focus now id=2:2 async=true" })
        XCTAssertEqual(world.warps, [center(1)])

        // The app kept its other window focused: one reassert at the settle.
        world.frontmost = 2
        world.focusedElements[2] = element(2)
        let settle = focus.takeSettleFocus(parked: [])
        XCTAssertEqual(settle.target, ids[1])
        XCTAssertFalse(settle.warp, "the warp was spent at motion start")
        XCTAssertTrue(world.logs.contains { $0.1.contains("focus reassert id=2:2 reason=sameAppDrift") })

        XCTAssertNil(focus.takeSettleFocus(parked: []).target, "consumed once")
    }

    func testInstantPassTakesTheIntentWithItsWarp() {
        focusLogically(2)
        focus.requestIntent(if: true, previous: ids[0])

        let settle = focus.takeSettleFocus(parked: [])

        XCTAssertEqual(settle.target, ids[2])
        XCTAssertTrue(settle.warp)
        focus.warpCursorToFocus(ids[2], plans: plans(2))
        XCTAssertEqual(world.warps, [center(2)])

        world.mouseFollowsFocus = false
        focus.warpCursorToFocus(ids[2], plans: plans(2))
        XCTAssertEqual(world.warps.count, 1)
    }

    func testFocusOnAnEmptyDisplayPutsTheCursorInItsMiddle() {
        // MM-02: `focus-monitor-*` onto a display with no window to focus.
        let display = CGRect(x: 1800, y: 0, width: 1600, height: 1000)
        focus.warpCursor(toDisplay: display)
        XCTAssertEqual(world.warps, [CGPoint(x: 2600, y: 500)])

        world.mouseLocation = CGPoint(x: 2000, y: 300)
        focus.warpCursor(toDisplay: display)
        XCTAssertEqual(world.warps.count, 1, "the cursor is already on that display")

        world.mouseLocation = CGPoint(x: 100, y: 100)
        world.mouseFollowsFocus = false
        focus.warpCursor(toDisplay: display)
        XCTAssertEqual(world.warps.count, 1, "mouse-follows-focus is off")
    }

    func testPassiveReflowFocusesNothing() {
        let settle = focus.takeSettleFocus(parked: [])
        XCTAssertNil(settle.target)
        XCTAssertFalse(settle.warp)
        focus.requestIntent(if: false, previous: ids[0])
        XCTAssertNil(focus.takeSettleFocus(parked: []).target)
    }

    func testClickCancelsThePendingIntent() {
        focusLogically(1)
        focus.requestIntent(if: true, previous: ids[0])
        focus.recordClick(at: center(0))
        scheduler.runPending()

        XCTAssertNil(focus.takeSettleFocus(parked: []).target)
    }

    func testTrailingActivationOfThePreviousFocusIsIgnored() {
        focusLogically(1)
        focus.requestIntent(if: true, previous: ids[0])
        world.frontmost = 1
        world.focusedElements[1] = element(0)

        focus.requestAdoption(.activation, pid: 1, element: nil)

        XCTAssertEqual(focused, ids[1])
        XCTAssertTrue(world.logs.contains { $0.1.hasPrefix("focus adopt ignored") })
    }

    func testCenterRequestsComeOnlyFromKeyboardIntentAndAreConsumed() {
        XCTAssertEqual(focus.takeCenterRequest(), .none)
        world.centerMode = .always
        focus.requestIntent(if: false, previous: ids[0])
        XCTAssertEqual(focus.takeCenterRequest(), .none)

        focus.requestIntent(if: true, previous: ids[0])
        XCTAssertEqual(focus.takeCenterRequest(), CenterRequest(mode: .always, previouslyFocused: ids[0]))
        XCTAssertEqual(focus.takeCenterRequest(), .none)
    }

    /// TG-03: a trackpad scroll that settled on another column raises its
    /// window like a key press, without centering (the snap chose the
    /// offset) or a cursor warp (the hand is on the trackpad).
    func testGestureIntentRaisesWithoutCenteringOrWarp() {
        world.centerMode = .always
        focusLogically(2)
        focus.requestGestureIntent()
        XCTAssertEqual(focus.takeCenterRequest(), .none)
        let settle = focus.takeSettleFocus(parked: [])
        XCTAssertEqual(settle.target, ids[2])
        XCTAssertFalse(settle.warp)
    }

    func testSizingFocusIsConsumedOnce() {
        focus.noteSizingFocus(ids[2])
        XCTAssertEqual(focus.takeSizingFocus(), ids[2])
        XCTAssertNil(focus.takeSizingFocus())
    }

    // MARK: Focus follows mouse

    func testHoverIsOffUnlessEnabled() {
        focus.pointerMoved(center(1))
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testHoverRestsThenFocusesOnce() {
        focus.focusFollowsMouse = true
        focus.setHoverFrames([ids[1]: frames[1], ids[2]: frames[2]])
        world.topPID = 2
        world.frontmost = 1
        world.mouseLocation = center(1)

        focus.pointerMoved(center(1))
        focus.pointerMoved(center(1))
        XCTAssertEqual(scheduler.pendingCount, 1, "coalesced to one look per 30 ms")
        scheduler.advance(by: 0.1)
        XCTAssertEqual(focused, ids[0], "rest delay not over")
        scheduler.advance(by: 0.05)

        XCTAssertEqual(focused, ids[1])
        XCTAssertEqual(world.reflows, 1)
        XCTAssertTrue(world.logs.contains { $0.1.contains("focus adopt source=hover id=2:2") })
        XCTAssertEqual(focus.takeSettleFocus(parked: []).target, ids[1], "hover asks the reflow to focus it")
    }

    func testHoverWaitsWhileAButtonIsDown() {
        focus.focusFollowsMouse = true
        focus.setHoverFrames([ids[1]: frames[1]])
        world.topPID = 2
        world.mouseLocation = center(1)
        world.mouseDown = true

        focus.pointerMoved(center(1))
        scheduler.advance(by: 0.5)

        XCTAssertEqual(focused, ids[0])
    }

    func testHoverIsSuppressedAfterACursorWarp() {
        focus.focusFollowsMouse = true
        focus.setHoverFrames([ids[1]: frames[1], ids[2]: frames[2]])
        world.topPID = 2
        focus.warpCursorToFocus(ids[2], plans: plans(2))
        XCTAssertEqual(world.warps, [center(2)])

        world.mouseLocation = center(1)
        focus.pointerMoved(center(1))
        scheduler.advance(by: 0.45)
        XCTAssertEqual(focused, ids[0], "suppressed for 400 ms after the warp")

        focus.pointerMoved(center(1))
        scheduler.advance(by: 0.3)
        XCTAssertEqual(focused, ids[1])
    }

    /// PF-AA: every pointer move over a managed window copied the whole
    /// on-screen window list (~33 a second), and resting in the focused
    /// window re-armed a no-op hover check every ~110 ms. Over the focused
    /// window alone there is nothing to focus: no lookup, nothing armed.
    func testMovingInsideTheFocusedWindowAsksTheWindowServerNothing() {
        focus.focusFollowsMouse = true
        focus.setHoverFrames([ids[0]: frames[0], ids[1]: frames[1], ids[2]: frames[2]])
        world.frontmost = 1
        world.topPID = 1
        for step in 0..<20 {
            world.mouseLocation = CGPoint(x: frames[0].minX + 10 + CGFloat(step), y: frames[0].midY)
            focus.pointerMoved(world.mouseLocation)
            scheduler.advance(by: 0.05)
        }
        XCTAssertEqual(world.topLookups, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)

        world.topPID = 2
        world.mouseLocation = center(1)
        focus.pointerMoved(center(1))
        scheduler.advance(by: 0.2)
        XCTAssertEqual(focused, ids[1], "another window still takes the focus")
        XCTAssertGreaterThan(world.topLookups, 0)
    }
}
