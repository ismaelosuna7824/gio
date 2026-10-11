# Multi-monitor: correct foundations, then niri monitor actions

## Objective
Two or more displays must behave correctly: frames flip with the right height, displays have
a geometric order, startup windows stay on their display, each display hides and switches
its own workspaces, and default-width columns fit their own display (MM-01). Niri monitor
actions (`focus-monitor-*`, `move-column-to-monitor-*`, `move-window-to-monitor-*`,
`move-workspace-to-monitor-*`) follow in MM-02. MM-04 repairs what the first live session on two
displays showed (2026-10-08): windows straddling displays, hot-plug, the overview's display and how
to send a window to another display.

## Problem (read-only code map, 2026-10-07)
- The global AX/WindowServer <-> Cocoa flip used `NSScreen.main` (the key-window screen):
  `SystemProbe.mainScreenFrame/mainScreenHeight`, `SessionHost.mainHeight()` (actuator,
  focus dim, render verification, snapshot matching, zoom bounds), `DiscoveryService`
  (`updateDisplayHeight(mainScreenFrame.height)`), `RestoreAssembly`, `gio-poc tile`. With the
  key window on a secondary display of another height every conversion used the wrong height.
- "First display" meant the lowest `CGDirectDisplayID` (`snapshotDisplayList`,
  `DisplayManager.allDisplays`), not the primary or the leftmost display.
- `SessionHost.initialSync` enumerated windows before registering displays, so every
  startup window went to the placeholder stack, adopted by the first display: windows on
  display B were pulled into display A's stack.
- `ReflowPlanner.planInactiveWorkspaces` parked every hidden workspace below the first
  display, whatever display owned it.
- `ReflowPlanner.plan` let only display index 0 carry the workspace-switch motion
  (`carriesSwitch = index == 0`): a switch on display B snapped instead of sliding.
- `SessionHost.engine()` resolved `default-column-width` against `NSScreen.main`'s width:
  `.standard` columns on a display of another width got the wrong width.
- `ActionApplier.focusedDisplay` fell back to the first display.
- Focusing a window on another display's shown workspace (`revealOnOtherWorkspace` ->
  `showWorkspace`) noted a `.workspaceSwitch` motion cause although nothing switched.

## Scope (MM-01)
In: the eight fixes above, a pure neighbour helper for MM-02, docs. Out: new
`HotkeyAction`/`CLICommand` cases (MM-02), the overview on other displays, managed-Space
detection on secondary displays (documented only), legacy `GioMac`/`GioApp`.

## Decisions
- One primary rule, `primaryDisplayIndex` (GioCore): the display at the Cocoa origin, else the
  first. `SystemProbe.primaryScreenFrame/primaryScreenVisibleFrame/primaryScreenHeight` and
  `GioMacOS.primaryScreen()` are the only sources; `DiscoveryService.syncDisplays` takes the
  flip height from the primary snapshot (the `mainScreenFrame` context closure is gone).
  Snapshot capture and frame pacing already used `NSScreen.screens.first`; they now call
  `primaryScreen()` too.
- Position order (`displaysByPosition`): `minX` ascending, then `maxY` descending (top
  first), then the ID. Applied in `snapshotDisplayList`, `DiscoveryService.syncDisplays` (so the
  rule holds whatever the host passes), `DisplayManager.allDisplays()`, and
  `WorkspaceManager.displayIDs` (the order now follows each `syncDisplays` call instead of
  registration). Consequence: `[[workspace]] display = N` counts the non-main displays left to
  right. The main display adopts the placeholder stack and the initial focus (it used to be the
  first display in the list).
- Startup placement: displays are synced before the first scan; every full scan (startup,
  resync) places a window no rule routes on `displayFor(frame:displays:)` (largest overlap with
  the usable frames; even split -> first in position order; no overlap -> focused display)
  through `arrivalDestination(_:onDisplay:)`. Named and indexed rules keep precedence (an
  indexed rule still resolves on the focused display). Created events and launch scans (live
  arrivals) still go to the focused display, like niri.
- Hidden parking per owner: a hidden window parks below the display whose stack holds it (a
  stack without a connected display uses the first display); one parking memo per display.
- Switch motion per display, by ownership rather than by "which display changed": each display
  takes the hidden windows parked below it (`ParkedTarget.display == display.frame`) and the
  revealed floating windows of its own shown workspace. A display that did not switch has none,
  so the motion follows the display that switched; with one display the inputs are identical to
  before (the single-display equivalence tests with the legacy reference still pass).
- Default width: `makeLayoutConfig()` no longer takes a viewport; a fraction is stored as
  `LayoutConfig.defaultColumnProportion` and resolved by the engine per viewport; points stay
  `defaultColumnWidth`. `GioConfig.resolveDefaultColumnWidth(viewportWidth:)` was removed (only
  tests used it).
- `ActionApplier.focusedDisplay`: the display showing `currentID`, else the display with
  `manager.focusedDisplay`, else none (the primary visible frame fallback for the viewport).
- `WindowFocusPlan.revealsHiddenWorkspace` / `revealCause`: `.workspaceSwitch` only when the
  workspace is not on screen; `.passive` when only the focused display changes.
  `FocusCoordinator.Context.showWorkspace` takes the cause. (The NA-04 note in
  `spaces-and-reveal.md` describes the earlier single-display behaviour.)
- MM-02 contract: `displayNeighbour(of:direction:frames:)` only considers displays past the
  matching edge (1 pt tolerance), prefers overlap on the perpendicular axis, then the nearest
  edge, then the nearest centre, then position order. `focusedDisplay` stays the single source
  of the current display.
- MM-02 shape: four direction-parameterized `HotkeyAction` cases (`focusMonitor`,
  `moveColumnToMonitor`, `moveWindowToMonitor`, `moveWorkspaceToMonitor`, each
  `(FocusDirection)`), one catalog entry and config name per direction in a new **Monitors**
  category. Defaults `Ctrl+Alt+H/J/K/L` (focus) and `Ctrl+Alt+Shift+H/J/K/L` (column), checked
  free in `defaultHotkeyBindings` (48 bindings); window and workspace moves ship unbound.
  `Alt+H/L` unchanged. No CLI verbs.
- Direction -> display: `ActionApplier` runs `displayNeighbour` over the `DisplayState` frames
  (full frames, as MM-01's contract) from `manager.focusedDisplay`. Core use cases take the
  target `DisplayID`: `WorkspaceManager.focusDisplay(_:)`, `moveColumn(toDisplay:)`,
  `moveWindow(toDisplay:)`, `moveWorkspace(toDisplay:)`; false and no mutation for a no-op
  (same or unknown display, nothing to move).
- Column and window moves insert after the target workspace's focused column (first when it is
  empty), focused, like niri; the column keeps its windows, width, weights and maximize state
  under a fresh column id. The source keeps a valid focus (the column that takes the index) and
  stays shown on its display even when emptied, until left (niri behaviour, and the NF-02
  "active may be empty" invariant). The window move reuses the `transfer` extraction
  (`detach`), so height weights and column repair match `move-to-workspace N`.
- Workspace move: inserted after the target's active workspace, but after its named block and
  before its trailing spare; shown there and focused. The source shows the workspace below, or
  the one above when only the spare is below (the spare when nothing else is left). Refused for
  an empty workspace (nothing to carry, it would only churn spares) and a named one (it lives on
  the display config assigns; `arrangeNamed` would move it back). A moved dynamic workspace
  stays on its new display across `syncDisplays`.
- Effects: a successful action sets `syncsShownWorkspace` (only then; a no-op syncs nothing)
  and every monitor action carries a focus intent. Motion causes: `.windowMovement` for column
  and window moves, `.workspaceSwitch` for focus and workspace moves.
- Warp decision: the window warp (`warpCursorToFocus`) only runs for a focus target, so
  `focus-monitor-*` onto a display with no window would leave the cursor on the old display.
  `ActionEffect.warpsToDisplay` carries the target's usable frame in that case and the host
  calls `FocusCoordinator.warpCursor(toDisplay:)`: same `mouse-follows-focus` gate and
  `mouseFollowsFocusTarget` rule (no warp when the cursor is already on that display), hover
  suppression noted, right away (nothing has to land). Keyboard focus stays on the previous
  window then (no window to give it to; documented).
- MM-03 (review findings, `agent://MultiMonitorReview`):
  - Vertically stacked displays: a display whose band below (its width, one display height
    deep, `canSlideBelow`; edges that only touch do not count) intersects another display does
    not slide its workspace switch. `planWorkspaceSwitchMotion` (new `otherDisplays:`) gives
    its outgoing windows and the windows coming from below no pre-position and no flight: they
    jump at the final pass, as non-first displays did before MM-01. Side entries and scrolling
    still animate (they stay in the display's own rows). Decided in Core, so the planner only
    passes the other displays' frames; the risers are dropped from the ordinary motion too, so
    no diagonal flight from the corner below crosses the lower display.
  - Hidden parking rule (`hiddenTarget`): bottom-right, bottom-left, then off the right side,
    then the left side (edges `.right`/`.left`, level with the display's top, its bottom when
    the window is taller; `isParked` accepts them like side parking), then the bottom-right
    corner of the union of all displays, where at most the 1 pt sliver touches the display in
    that corner. The sides were outside the hidden rule because of the side-parking band; they
    are only used when the band below is taken, and overlapping off-screen windows are
    harmless. The union corner is unseen live (macOS may clamp a window whose sliver is on no
    display).
  - Floating windows in monitor moves: option (a), moved physically. `ReflowPlanner` keeps the
    connected display whose stack held each floating window at the last pass; when it changes,
    `planFloatingRelocations` / `relocatedFloatingFrame` translate the frame (the remembered
    one when hidden) by the visible-frame origin delta and clamp it inside the target's visible
    frame, size kept (a larger window pinned to the top-left). The result goes into
    `HiddenWindowBook.move(_:to:)`, so the existing shown-floating path writes it through the
    reconciler, keeps it across retargets until it lands, and a hidden window returns there.
    State-driven, so `move-workspace-to-monitor` is covered too, and no use case or
    `ActionApplier` change. Not moved: a window seen for the first time, one already centred
    on its new display (dragged there by the user earlier), one whose old display is gone
    (macOS moved it) and a minimized one. A floating window dragged to another display by hand
    still belongs to its workspace's display, as before (no relocation without a membership
    change). Option (b) (refuse) was rejected: niri moves floating windows between monitors
    and the book already held per-window floating frames.

## Tasks
- [x] MM-01 — Multi-display foundations. Commit `ecfd426` (MM-01..MM-03 in one commit).
  - [x] 1. Flip with the primary display height: `GioCore/Display/DisplayGeometry.swift`
    (`primaryDisplayIndex`), `GioSession/Seams/SystemProbe.swift`,
    `GioMacOS/Displays/DisplayList.swift` (`primaryScreen()`),
    `GioSession/Events/DiscoveryService.swift`, `GioDesktop/SessionHost.swift`
    (`primaryHeight()` for the actuator, focus dim, render verification, snapshot matching,
    zoom bounds, discovery, resync; snapshot capture and refresh store),
    `GioMacOS/Assembly/RestoreAssembly.swift`, `GioPOC/main.swift`.
  - [x] 2. Position order: `displaysByPosition`; `snapshotDisplayList`,
    `DiscoveryService.syncDisplays`, `DisplayManager.allDisplays`,
    `WorkspaceManager.syncDisplays` (host order, main adopts the placeholder).
  - [x] 3. Startup placement: `SessionHost.initialSync` order, `DiscoveryService`
    (`displayFrames` context, `registerNew(placement:)`), `displayFor(frame:displays:)`,
    `WorkspaceManager.arrivalDestination(_:onDisplay:)`.
  - [x] 4. Hidden workspaces park below their own display: `ReflowPlanner.planInactiveWorkspaces`.
  - [x] 5. Switch motion carried by the display that switched: `ReflowPlanner.plan`.
  - [x] 6. Default column width per display: `LayoutConfig.defaultColumnProportion`,
    `GioConfig.makeLayoutConfig()`, `SessionHost.engine()`, `TileAssembly`.
  - [x] 7. `ActionApplier` falls back to the focused display.
  - [x] 8. Reveal on another display's shown workspace is `.passive`:
    `WindowFocusPlan.revealCause`, `FocusCoordinator`, `SessionHost.showWorkspace`.
  - [x] 9. Docs: `docs/ARCHITECTURE.md` (Multiple displays, parking table, coordinate spaces),
    `docs/TESTING.md` (manual check 14, known limitations), this file.
- [x] MM-02 — Niri monitor actions on `displayNeighbour`. Commit `ecfd426`; LIVE PENDING.
  - [x] 1. Actions and config: `GioCore/Hotkeys/HotkeyDispatcher.swift` (cases, defaults),
    `ShortcutCatalog.swift` (Monitors category, entries), `Config/ConfigParser.swift`
    (`parseActionName`, `validActionNames`), `Focus/FocusIntent.swift`
    (`carriesFocusIntent`), `Config/AnimationKinds.swift` (`motionCause`).
  - [x] 2. Core use cases: `GioCore/Workspace/WorkspaceManager.swift` (`focusDisplay`,
    `moveColumn(toDisplay:)`, `moveWindow(toDisplay:)`, `moveWorkspace(toDisplay:)`;
    `transfer` split into `detach` / `insert`).
  - [x] 3. Wiring: `GioSession/Actions/ActionApplier.swift` (`toNeighbour`,
    `ActionEffect.warpsToDisplay`), `GioSession/Focus/FocusCoordinator.swift`
    (`warpCursor(toDisplay:)`), `GioDesktop/SessionHost.swift` (`apply`).
  - [x] 4. Docs: `ConfigTemplate.swift` comment, `docs/USER_GUIDE.md` (Multiple monitors
    concept, shortcuts rows, 48 bindings, action names, Monitors category),
    `docs/ARCHITECTURE.md` (MM-02 paragraph), `docs/TESTING.md` (check 14b, limitation),
    `docs/CONTRIBUTING.md` (binding count), this file.
- [x] MM-03 — Review fixes: stacked displays and floating monitor moves. Commit `ecfd426`;
  LIVE PENDING.
  - [x] 1. Switch motion off the display below: `GioCore/Animation/WorkspaceSwitchMotion.swift`
    (`canSlideBelow`, `planWorkspaceSwitchMotion(otherDisplays:)`),
    `GioSession/Reflow/ReflowPlanner.swift` (passes the other displays).
  - [x] 2. Hidden parking off every display: `GioCore/Layout/WorkspaceVisibility.swift`
    (`hiddenTarget` candidates).
  - [x] 3. Floating windows follow monitor moves: `WorkspaceVisibility.swift`
    (`HiddenWindowBook.move`, `relocatedFloatingFrame`, `planFloatingRelocations`),
    `ReflowPlanner.planInactiveWorkspaces(visibleFrames:)` (`relocateFloatingWindows`),
    `GioDesktop/SessionHost.swift` (passes `visibleFrames`).
  - [x] 4. Docs: `docs/ARCHITECTURE.md` (Multiple displays, parking table), `docs/USER_GUIDE.md`
    (Multiple monitors), `docs/TESTING.md` (checks 14 and 14b, known limitation), this file.

## Evidence
- RED observed (assertion failures, `swift test --filter`, before the code):
  - `WorkspaceManagerTests.testTheMainDisplayAdoptsThePlaceholderStackWhateverItsPosition`:
    focused display 11, expected 12.
  - `DisplayManagerTests.testAllDisplaysFollowGeometryNotIDs`: `[1, 2, 3]`, expected `[2, 3, 1]`.
  - `DiscoveryServiceTests.testDisplaySyncFlipsWithThePrimaryDisplayHeight`: 1169, expected 982.
  - `DiscoveryServiceTests.testDisplaySyncOrdersDisplaysByPositionAndFocusesTheMainOne`:
    `[3, 2, 1]` and focus 3, expected `[1, 2, 3]` and 2.
  - `DiscoveryServiceTests.testStartupScanPlacesEachWindowOnTheDisplayItSitsOn`: all four
    windows on display 2 (`[7, 8, 9, 10]`), display 3 empty.
  - `ReflowPlannerTests.testHiddenWorkspaceParksBelowTheDisplayThatOwnsIt`: parked against the
    left display frame and overlapping it.
  - `ReflowPlannerTests.testTheDisplayThatSwitchedCarriesTheSwitchMotion`: no drop animation,
    no `.workspaceSwitch` kind.
  - `ReflowPlannerTests.testStandardColumnsResolveAgainstTheirOwnDisplaysWidth`: 888 on the
    1600 pt display, expected 788.
  - `ActionApplierTests.testAWorkspaceNoDisplayShowsYetResolvesOnTheFocusedDisplay`: the left
    display's frame, expected the right one.
- RED by compilation (new API): `DisplayGeometryTests` (`primaryDisplayIndex`,
  `displaysByPosition`, `displayFor`, `displayNeighbour`), `FocusWindowPlanTests`
  (`revealCause`), `SystemProbeTests` (`primaryScreenFrame/Height`), `ConfigTests` /
  `RevealGeometryTests` (`makeLayoutConfig()`, `defaultColumnProportion`),
  `NamedWorkspaceManagerTests.testAStartupWindowLandsOnItsDisplayUnlessARuleRoutesIt`
  (`onDisplay:`), `FocusCoordinatorTests.testRevealOnAnotherDisplaysShownWorkspaceIsNotAWorkspaceSwitch`
  (`showWorkspace` cause).
- Regression guards (passed before and after):
  `DiscoveryServiceTests.testALiveArrivalGoesToTheFocusedDisplayWhereverItOpens`,
  `ReflowPlannerTests.testTwoDisplaysMatchLegacyWithoutHiddenWorkspaces` (renamed from
  `...OnlyTheFirstCarriesTheSwitch`), every single-display legacy-equivalence test.
- GREEN: `swift test`, all bundles 0 failures: GioUITests 250 (53 skipped), GioSessionTests
  289, GioPOCTests 7, GioMacTests 19, GioMacOSTests 40, GioCoreTests 1286. Signed `xcodebuild`
  BUILD SUCCEEDED. `git diff --check` clean.
- LIVE PENDING (nothing validated on real displays):
  - Displays of different heights, key window on the secondary: windows land at the right
    height on both (flip), focus dim and render verification match.
  - Second display arranged left of the laptop: display order and initial focus on the laptop.
  - Start Gio with windows on both displays: each stays on its display.
  - Switch workspaces on the secondary display: hidden windows drop below that display (never
    onto the other) and the switch slides there.
  - Default-width columns are half of each display.
  - Click a window on the other display: focus moves there, no workspace slide.
  - Unplug/replug: survivor keeps its windows (unchanged behaviour, still unvalidated live).
  - Known gap, not addressed: managed-Space detection on secondary displays with "Displays
    have separate Spaces".

## Evidence (MM-02)
- RED by compilation (`swift build --build-tests` before any production code):
  `HotkeyTests.swift` "type 'HotkeyAction' has no member 'focusMonitor' / 'moveColumnToMonitor'
  / 'moveWindowToMonitor' / 'moveWorkspaceToMonitor'"; the new tests in
  `WorkspaceManagerTests`, `NamedWorkspaceManagerTests`, `FocusIntentTests`,
  `PerAnimationConfigTests`, `ShortcutCatalogTests` (Monitors category), `ActionApplierTests`
  (`warpsToDisplay`), `FocusCoordinatorTests` (`warpCursor(toDisplay:)`) and
  `ReflowPlannerTests` were written in the same step against the missing API.
- First GREEN run: one failure in a new test,
  `testMovingTheOnlyNonEmptyWorkspaceLeavesTheSourceOnItsEmptyOne`, which asserted the
  target's spare keeps its id; `normalize` always replaces an inactive spare with a new one, so
  the test now checks the structure (moved first, `[1, 0]` windows).
- New tests: `WorkspaceManagerTests` (focus display and no-ops; column move after the focused
  column with widths, weights and source focus; into an empty display; window move as its own
  column; no focused window; three displays leaving the middle alone; workspace move after the
  target's active with the source on the one below / above / its spare; no-ops; the property
  test now runs 3 displays with the four use cases), `NamedWorkspaceManagerTests` (named
  workspace refused, its columns move; dynamic workspace lands after the target's named block
  and survives a resync; property test with the moves), `HotkeyTests` (defaults, names,
  unbound families, Alt+H/L unchanged), `ShortcutCatalogTests`, `FocusIntentTests`,
  `PerAnimationConfigTests`, `ActionApplierTests` (no neighbour / one display: manager
  unchanged, no sync; focus monitor and empty-display warp; moves match Core and focus
  follows), `FocusCoordinatorTests` (display warp honours mouse-follows-focus and an
  on-display cursor), `ReflowPlannerTests` (end to end: action, sync, pass lay the moved
  column / workspace out on the right display).
- GREEN: `swift test`, all bundles 0 failures: GioUITests 250 (53 skipped), GioSessionTests
  295, GioPOCTests 7, GioMacTests 19, GioMacOSTests 40, GioCoreTests 1301. Signed
  `xcodebuild` BUILD SUCCEEDED. `git diff --check` clean.
- LIVE PENDING (nothing validated on real displays; `docs/TESTING.md` check 14b):
  - `Ctrl+Alt+H/J/K/L` focuses the neighbour; cursor to the window, or the display middle when
    it shows none; keyboard focus stays put on an empty display.
  - `Ctrl+Alt+Shift+H/J/K/L` moves the column (stacked windows, width) next to the target's
    focused column and keeps focus; motion between displays looks right.
  - Bound `move-window-to-monitor-*` / `move-workspace-to-monitor-*` behave as documented; the
    source display shows its neighbouring workspace and hidden windows park on the right display.
  - Edge presses (no display that way) change nothing.

## Evidence (MM-03)
- RED observed (`swift test --filter`, signatures only, before the behaviour):
  - `WorkspaceSwitchMotionTests.testOutgoingWindowDoesNotDropOntoADisplayBelow` and
    `testIncomingWindowFromBelowSnapsWhenADisplayIsBelow`: drop animation, riser pre-position and
    flight planned (3 failures).
  - `WorkspaceVisibilityTests.testBothBottomCornersBlockedHangOffTheFreeSide` (`corner`, maxY 1,
    overlapping the display below), `testBottomCornersAndRightSideBlockedHangOffTheLeftSide`,
    `testEverySideBlockedHangsOffTheBottomRightOfAllDisplays` (x 1799, expected 4999),
    `testHiddenWindowsOfAnUpperDisplayNeverLandOnTheDisplayBelow` (equal widths: parked
    `(1799, 170, 900, 1000)` on the lower display) — 11 failures.
  - `ReflowPlannerTests.testTheUpperDisplaysSwitchNeverSlidesOntoTheDisplayBelow` (upper
    `(0,1169,1920,1080)` and `(0,1169,1800,1080)` over `(0,0,1800,1169)`): 14 failures, flights
    `(40,1229) -> (40,470)` onto the lower display, parked `(1799,470,450,700)` on it, risers
    pre-positioned at `y 146` and rising across it.
  - `ReflowPlannerTests.testAFloatingWindowMovedToAnotherDisplayIsWrittenThere`: no frame
    planned (`nil`, expected `(2100,200,600,400)`) for the window, column and workspace moves;
    `testAMovedFloatingWindowHidesWithItsNewDisplayAndReturnsThere` crashed on the missing frame.
- RED by compilation: `canSlideBelow`, `HiddenWindowBook.move`, `relocatedFloatingFrame`,
  `planFloatingRelocations` tests.
- Regression guards (passed before and after):
  `ReflowPlannerTests.testTheLowerDisplayStillSlidesThroughItsFreeBottomEdge`,
  `WorkspaceVisibilityTests.testSideBySideDisplaysKeepTheBottomCorners`, every single-display
  and side-by-side legacy-equivalence test (the legacy reference passes `otherDisplays: []`).
  `testAllCornersBlockedFallsBackToBottomRight` encoded the defect (bottom-right on the display
  below) and was replaced by the side and union-corner tests.
- GREEN: `swift test`, all bundles 0 failures: GioUITests 250 (53 skipped), GioSessionTests
  299, GioPOCTests 7, GioMacTests 19, GioMacOSTests 40, GioCoreTests 1314. Signed
  `xcodebuild` BUILD SUCCEEDED. `git diff --check` clean.
- LIVE PENDING (nothing validated on real displays; `docs/TESTING.md` checks 14 and 14b):
  - Display above the laptop: its switch does not slide, nothing of it shows on the laptop, its
    hidden windows sit off its bottom corner or side; the laptop still slides.
  - Floating window with `Ctrl+Alt+Shift+L` / `move-window-to-monitor-*` /
    `move-workspace-to-monitor-*`: lands on the target display (size, offset, clamped), then
    hides and returns with the target display's workspace.
  - The union-corner fallback (every side of a display touching another) has not been seen.

## MM-04 — Live repair: straddling windows, hot-plug, overview display, Move to Display

### Live evidence (user, 2026-10-08 23:29-23:40 UTC)
- Arrangement (read from `NSScreen`): built-in id 1, frame `(0,0,1800,1169)`, visible
  `(0,0,1800,1130)`, scale 2, 120 Hz, primary; external id 3, frame `(-2160,-224,2160,1440)`, visible
  the same, scale 1, 60 Hz, left of the built-in (bottom 224 pt lower, top 47 pt higher: AX top
  y = 1169 - 1216 = -47, bottom 1393).
- Config: named `Code` with `display = 2`, `Browsers` on main, `center-focused-column =
  "on-overflow"`. (The config file read on 2026-10-08 17:13 local no longer has `display = 2`;
  the tests use the reported one.)
- Symptoms: windows pass to the other monitor and straddle; on the built-in, after Alt+H/L, two half
  columns and empty desktop on the right; Alt+O always on the same display; worse after
  connecting a monitor while Gio runs; no way known to send a window to another display.
- Log (`~/.config/gio/gio.log`, read only): no display line at all; `reconcile failure
  id=39335:14 app=Activity Monitor kind=frameMismatch requested=(-1076,-216,1068,1394)
  actual=(-1076,0,1068,1178)` (23:38:09); `requested=(-538,-216,1068,1394)
  actual=(-538,-264,1068,1394)` for Activity Monitor (23:39:10) and LoopOps ADE (23:36:48 and
  six more). Every `overview shown` (`workspaces=2 windows=5`) listed the external's stack
  (WhatsApp, Slack, OrbStack, LoopOps ADE, Activity Monitor), each opened while a window of the
  external had the focus.

### Causes
Proven (arithmetic on the log plus a RED test):
1. **Peeking columns straddle displays (symptoms 1 and 2).** On the external, columns are 1068 pt
   (half of 2160 after padding). A centered column k sits at offset `1076k - 538`; its right
   neighbour then starts at x = -538 and ends at 530, half on the built-in. That is exactly the
   logged `requested=(-538,...)`. macOS pushed it down to y = -264 (its top under the built-in's
   menu bar, AX y 39): the `frameMismatch`. Mirror case: the built-in's left neighbour of a
   centered column, `(-440,8,888,1114)`, lies half on the external. `planParking` kept every
   frame that intersected the viewport visible, whatever display the rest of it covered.
2. **Not a flip bug.** The failure line logs the Cocoa frame the actuator was asked for (before
   `AXVerticalFlip`). Flipped with the primary height 1169 the request is AX `(-1076,-9,1068,1394)`,
   inside the external's AX bounds `(-2160,-47,2160,1440)`. `primaryHeight()`, `AXVerticalFlip`,
   `cocoaFrame(fromWindowServer:)` and the discovery flip all use the primary display (MM-01).
   Guard test, green before and after.
3. **Hot-plug left two displays on one workspace.** `DisplayManager.connect` kept a known
   display's workspace ("never steals"). Connecting the external moves `Code` (`display = 2`)
   there, but the built-in, which showed `Code`, kept pointing at it: both displays showed `Code`
   until the next pass's `syncShownWorkspace` (and the facts, actions and visibility checks in
   between read the stale pair). RED: `[2, 2]`, expected `[2, 3]`.
4. **An empty screen list disconnected every display** in the host's `DisplayManager` while the
   manager kept its stacks (the manager ignores an empty list). RED: displays `[]`, two
   `displaysChanged` calls.
5. **No coalescing**: every `didChangeScreenParametersNotification` (macOS posts several per
   plug) ran a full sync and a reflow, each animating from frames macOS had just changed.
6. **No display logging** (nothing to diagnose the arrangement from).
7. **Overview display (symptom 3)**: `workspaceOverview()` always used `manager.focusedDisplay`.

Inferred (not proven):
- Activity Monitor's `actual=(-1076,0,1068,1178)`: macOS cut the height at the built-in's bottom,
  presumably because the window, straddling just before, still counted as on the built-in when
  its position was written. Without straddling it should not recur.
- The requested height 1394 means a 1410 pt usable height on the external at 23:38, not the 1440
  read later (a 30 pt top inset then, a menu bar on the external?). Unknown; the new `display`
  line records the visible frame at every change.
- Symptom 2 is not a viewport or content-width defect: with the exact arrangement and three
  half-width columns centered on the built-in, the planner keeps the right neighbour visible
  (test), and the log's built-in steps (`applied=2 parked=1`, no centering: two 888 pt columns
  never overflow 1800 pt) are sane. The empty/half columns seen were most likely the straddlers
  (the external's right peek over the built-in's left part, and macOS moving straddlers).
  `center-focused-column` applies to the display showing the current workspace with that
  display's viewport (`ReflowPlanner.plan`, `display.workspace == manager.currentID`); checked by
  reading and by the centered tests on both displays.
- Symptom 3: the focus Gio adopts follows clicks and activations (`focus reveal` lines), so the
  overview followed it in this log; it can only lag when the focus goes to a window Gio did not
  adopt, or when the user is on a display whose workspace is empty.

### Decisions
- **No straddling.** A frame that intersects the viewport but also another display parks like an
  off-viewport column (`planParking`). Clipping by resizing was rejected (every scroll would
  resize apps; minimum widths would straddle again). A peek over a free edge stays (off every
  display, as on one display); the focused column always stays visible (`focusedColumn`), even one
  wider than its display. Test assertions for the external accept a left peek past its free edge
  (AX x below -2160): that is off every display, not on the built-in.
- **Far-side parks jump.** `ParkedTarget.farSide` marks a park whose preferred edge is taken by
  another display (the far edge or the corner). `ReflowPlanner` drops the flight of such a park
  and of a window returning from one (`farParked`, last pass) and pre-positions it at its target
  (`ReflowPlan.jumps`); the snapshot flight starts those layers at their target
  (`drive(jumps:)`). Before, a column leaving over the shared edge flew across the whole display.
- **Hot-plug.** `DiscoveryService.noteDisplayChange()` coalesces a burst: one sync and one reflow
  `displayChangeDelay` (0.25 s) after the last notification (generation-checked one-shot on the
  session scheduler); a running snapshot flight is still aborted at once. `syncDisplays` ignores
  an empty list, points known displays at the manager's active workspace too (`DisplayManager.connect`
  semantics changed; `testReconnectRefreshesFrameAndKeepsOffset` encoded the old rule and became
  `...FollowsTheSyncedWorkspace`), logs the configuration, and `displaysChanged` now also arms
  `InstantPlacementReason.displays` (the next pass lands without motion: macOS moves windows of a
  removed display, so the known frames are stale). Audited without change: per-display parking
  memos and the hidden book (`invalidateParking`), floating relocation (a gone display is not a
  move), snapshot overlay panels/backdrops (the overlay prunes gone displays itself), focus dim
  panels (keyed by display frame, gone ones fade out), the flip height update.
- **Display numbers.** One user-facing numbering everywhere: `displaysByNumber` (primary 1, then
  position order), the same as `WorkspaceManager.display(numbered:)` / `[[workspace]] display`.
- **Logging.** Info at startup and every sync: `displays count=N`, then per display `display
  index=<position> id=<CGDirectDisplayID> frame=(x,y,w,h) visible=(x,y,w,h) scale=S hz=H
  primary=<bool> number=<display number> shown=<workspace id> stack=<ids>` (Cocoa). Debug: `display
  flip primaryHeight=H primary=<id>`. `displays count=0 ignored` for an empty list. Nothing extra
  per reflow.
- **Overview display rule.** The display holding most of the focused window (the frontmost app's
  front window from the WindowServer list, so focus Gio did not adopt counts), else the display
  under the cursor, else Gio's focused display (`overviewDisplay`, pure). Niri uses the focused
  output; this is the same whenever Gio adopted the focus. `ActionApplier.focusOverviewDisplay`
  makes it the focused display so the overview's `1`-`9` and picks act there; log `overview
  display id=N reason=focusedWindow|cursor|focusedDisplay`.
- **Moving windows between displays.** `move-window-to-monitor-*` is bound by default to
  `Ctrl+Alt+Cmd+H/J/K/L` (free in the 69-binding table, now 73; Ctrl+Alt is the monitor family,
  Shift the column as in niri, Command the window; niri itself leaves the window move as a
  commented alternative of its column-move combo). `move-column-to-monitor-*` unchanged. New CLI
  verb `move-window-to-display N` (it fits the `verb N` grammar of `workspace N`): IPC, launcher
  `> move-window-to-display N`, and the menu bar's **Move Window to Display** submenu (one row per
  display, `N  <NSScreen.localizedName>`, the focused window's display checked and disabled,
  hidden with one display). The config template's example moved to `Ctrl+Alt+Shift+Cmd+L`.

### Tasks
- [x] MM-04 (`e564c8d`) — Live repair. LIVE PENDING.
  - [x] 1. Instrumentation: `GioCore/Display/DisplayLog.swift` (`DisplayLogEntry`,
    `displayConfigurationLog`, `displayFlipLogLine`), `GioMacOS/Displays/DisplayList.swift`
    (`DisplaySnapshot.scale/refreshRate`), `DiscoveryService.syncDisplays` (`logDisplays`).
  - [x] 2. No straddling: `GioCore/Layout/ParkingPlanner.swift` (`planParking` straddlers,
    `focusedColumn`, `ParkedTarget.farSide`), `DisplayReflowPlanner.swift` (passes the focused
    column), `GioSession/Reflow/ReflowPlanner.swift` (`jumps`, `farParked`),
    `GioSession/Snapshot/SnapshotFlightController.swift` (`drive(jumps:)`), `SessionHost` (passes
    `pass.jumps`).
  - [x] 3. Symptom 2 reproduced on the exact arrangement (no extra defect; see Causes).
  - [x] 4. Hot-plug: `DiscoveryService.noteDisplayChange` / `displayChangeDelay`, empty-list guard,
    `DisplayManager.connect`, `InstantPlacementReason.displays`, `SessionHost.watchDisplays` and
    `displaysChanged`.
  - [x] 5. Overview display: `GioCore/Display/DisplayGeometry.swift` (`overviewDisplay`,
    `displaysByNumber`), `ActionApplier.focusOverviewDisplay`, `SessionHost.focusOverviewDisplay`.
  - [x] 6. Move to Display: `HotkeyDispatcher.defaultHotkeyBindings`, `CLICommand`
    (`moveWindowToDisplay`, usage), `CommandDispatcher`, `FocusIntent`, `IPCRouter`,
    `GioUI/LauncherModel.swift`, `GioUI/MoveToDisplayMenu.swift`, `GioUI/MenuBar.swift`,
    `ConfigTemplate.swift`.
  - [x] 7. Docs: `docs/USER_GUIDE.md` (Multiple monitors, shortcuts table, 73 bindings, menu bar,
    overview, CLI), `docs/ARCHITECTURE.md` (Multiple displays MM-04 bullets, parking table,
    instant placement), `docs/TESTING.md` (checks 14 and 14b, log lines, known limitations),
    `docs/CONTRIBUTING.md` (73), this file.

### Evidence
- RED by compilation (`swift build --target ...`, before the code): `GioCoreTests/MultiDisplayRepairTests`
  (`ParkedTarget.farSide`, `displaysByNumber`, `overviewDisplay`, `displayConfigurationLog`,
  `DisplayLogEntry`, `displayFlipLogLine`, `InstantPlacementReason.displays`,
  `CLICommand.moveWindowToDisplay`); `GioSessionTests` (`SnapshotFlightTests` `farSide:` /
  `drive(jumps:)`, `MultiDisplayHotPlugTests` `DisplaySnapshot(scale:refreshRate:)`,
  `noteDisplayChange`, `ActionApplier.focusOverviewDisplay`, `ReflowPlan.jumps`); `GioUITests`
  (`MenuDisplay`, `moveToDisplayItems`).
- RED observed (assertions, `swift test --filter`, with the new API in place and the old behaviour):
  - `MultiDisplayRepairTests.testAColumnPeekingOverASharedEdgeParksOffItsDisplaysFreeSide`:
    `(-538,-216,1068,1424)` stayed visible, no park.
  - `testTheBuiltInsLeftPeekNeverReachesTheExternal`: `(-440,8,888,1114)` visible.
  - `testTheExternalStripStaysInsideTheExternalsAXBounds`: focus 1 and 2, `(-538,-216,1068,1424)`
    visible, AX maxX 530 > 0.
  - `testTheBuiltInStripKeepsItsRightNeighbourAndNeverReachesTheExternal`: left neighbour
    `(-440,8,888,1114)` on the external.
  - `testAColumnWiderThanTheRoomAtTheEdgeNeverStraddles`: 7 straddlers, e.g. external
    `(-644,-216,1500,1424)`, built-in `(-1058,8,1300,1114)`.
  - `FarSideParkingMotionTests` (both): no far-side park, the return flew (no jump, no pre-position).
  - `MultiDisplayHotPlugTests.testConnectingAndDisconnectingTheExternalKeepsEveryWindowOnItsDisplay`:
    display workspaces `[2, 2]` after connecting (expected `[2, 3]`).
  - `testEveryDisplaySyncLogsTheConfiguration`: no log line.
  - `testAnEmptyScreenListKeepsTheConnectedDisplays`: displays `[]`, `displayChanges` 2.
  - `HotkeyTests`: 69 bindings (expected 73), `Ctrl+Alt+Cmd+H/J/K/L` unbound.
- Green before and after (guards): `testTheFlipUsesThePrimaryHeightAndKeepsExternalFramesOnTheExternal`,
  `testAPeekTowardsNoDisplayStaysVisible`, every `ReflowPlannerTests` legacy-equivalence test, the
  MM-03 stacked-display tests.
- Tests that encoded the old decisions, updated: `DisplayManagerTests.testReconnectRefreshesFrameAndKeepsOffset`
  (now `...FollowsTheSyncedWorkspace`), `HotkeyTests` (count, window moves bound),
  `ShortcutCatalogTests.testMonitorEntriesOnePerDirectionWithCtrlAltDefaults` (window moves bound),
  `RegistrationRetryGuardTests.testOwnPidIsNeverClassifiedNorRetried` (clears the set-up sync's
  display lines before asserting the own-pid path logs nothing).
- GREEN: `swift test`, all bundles 0 failures: GioUITests 306 (53 skipped), GioSessionTests 393,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 83, GioCoreTests 1653. `git diff --check` clean.
  Signed `xcodebuild` not run in this session (GioMacOS, GioUI and GioDesktop changed: run it).
- LIVE PENDING (nothing validated on real displays; `docs/TESTING.md` checks 14 and 14b):
  - The exact arrangement (external left, bottom 224 pt lower): no window on both displays after
    Alt+H/L, overview picks and centering on either display; no `frameMismatch` across the edge.
  - Hot-plug while Gio runs, with `Code` at `display = 2`: one `displays count=` block per plug or
    unplug, `layout instant reason=displays`, `Code` moves to the external and back, hidden windows
    park off their own display.
  - Far-side parks: the leaving peek vanishes instead of flying across the display, with both
    renderers.
  - Alt+O on each display (focused window there; empty workspace with the cursor there).
  - Menu bar **Move Window to Display**, `> move-window-to-display N`, `Ctrl+Alt+Cmd+H/L`.

## MM-05 — No minimum sizes learned across a display change

### Report
"The focus animation feels off: a small delay on each focus change, the motion looks slightly
stuck, and sometimes windows move or rearrange when they should not."

### Cause (from `~/.config/gio/gio.log.1`, 2026-10-09)
- 00:53:48, display change (`layout instant reason=displays`): workspace 7 came to the built-in
  (1800 pt). Its pass asked Slack `1440:2` and OrbStack `22787:9` for 888 pt; both stayed at the
  1068 pt of the external display's columns (`frameMismatch requested=(8,8,888,1114)
  actual=(8,8,1068,1114)`), and FI-02 logged `min size learned ... w=1068` for both. The book
  only grows and lives for the session, so those columns stayed 1068 wide.
- With `center-focused-column = "on-overflow"`, a 1068 column and an 888 one span 1964 > 1800, so
  every focus change between them centers the target: the whole strip slides on each key.
  Throwaway check (deleted): four 888 columns on 1800, focus 1,0,1,0 with `planDisplayLayout`:
  offsets `[0, 0, 0, 0]`; with a learned 1068 on the first column: `[628, 0, 628, 0]`.

### Decision
- A pass placed for a display change teaches no minimum (`MinimumSizeBook.learn(from:placement:)`,
  `placement == .instant(.displays)` returns nothing). macOS and the apps re-place windows across a
  reconfiguration, so a size that did not land then says nothing about a minimum. A real minimum
  fails again in the next pass and is learned there (one extra failed write, bounded).
- No new state: `SessionHost` hands the pass's `InstantPlacementDecision` it already computed to
  `instantPass` and `foldSettle`; passes collected after an overlay flight are `.animate`.

### Tasks
- [x] MM-05 (`fb27b68`) — `MinimumSizeBook.learn(from:placement:)`, `SessionHost.instantPass` /
  `foldSettle` / `learnMinimumSizes`, `docs/ARCHITECTURE.md` (Learned minimum sizes),
  `docs/TESTING.md` (`min size learned` row), this file.

### Evidence
- RED by compilation: `MinimumSizeTests.testDisplayChangePassTeachesNoMinimum` (extra argument
  `placement`).
- GREEN: `swift test`, all bundles 0 failures: GioUITests 306 (53 skipped), GioSessionTests 393,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 83, GioCoreTests 1654. Signed `xcodebuild` BUILD
  SUCCEEDED. `git diff --check` clean.
- LIVE PENDING: move a workspace between displays of different column widths (or plug/unplug the
  external): no `min size learned` in the pass after `layout instant reason=displays`. The
  2026-10-09 21:20 session had one display only: `min size learned` only for WhatsApp 970 and
  LoopOps 1024 (the real minimums), nothing for Slack or OrbStack.
- Not addressed here (report part 1, the per-key delay): see the issue triage; not reproduced.

## MM-06 — Move Edge: crossing displays at the strip's edge

### Request (2026-10-11)
OmniWM-inspired "Move Edge" (user decision in chat: both the niri actions and a toggle). niri's
`move-column-left-or-to-monitor-left`, `move-column-right-or-to-monitor-right`,
`focus-column-or-monitor-left`, `focus-column-or-monitor-right` (names and semantics checked in
niri's `niri-ipc/src/lib.rs` and `src/layout/mod.rs`: the in-strip move first, the output only
when it did nothing), plus OmniWM's `moveCrossesMonitorAtEdge` as
`[behavior] move-crosses-monitor-at-edge` for the plain `move-column-left/right`. OmniWM was only
read for behaviour (GPL-2.0); no code taken. Non-goals: Dwindle, gestures, SkyLight.

### Decisions
- Core: `WorkspaceManager.moveColumnOrToDisplay(_:frames:)` and `focusColumnOrDisplay(_:frames:)`
  (`GioCore/Workspace/MoveEdge.swift`, pure) run `moveColumn(in:direction:)` / `moveFocus`
  and only when that returns the workspace unchanged look up `displayNeighbour` and call
  `moveColumn(toDisplay:landing:)` / `focusDisplay`. Result `EdgeStep` (`.unchanged`,
  `.withinWorkspace`, `.crossedDisplay`); no neighbour, an empty workspace or up/down give
  `.unchanged` and leave the manager untouched. Left/right only (niri has no vertical variant).
- Landing (user requirement, differs from niri): the column enters by the edge it crossed.
  Moving right it becomes the target workspace's **first** column, moving left its **last**
  (`ColumnLanding.first` / `.last`); niri's `move_column_to_output` lands it after the target's
  active column. `move-column-to-monitor-*` keep `.afterFocused` (the default argument), as do
  `move-window-to-monitor-*` and the workspace transfers. The target's reveal is the pass's
  usual `revealOffset` (no stored offset is touched); a test plans the target display and finds
  the landed column inside it.
- Focus at the edge goes to the neighbouring display's shown workspace and its own focused
  column (`focusDisplay`, like niri's `focus_output`); an empty display gets the MM-02
  `warpsToDisplay` cursor warp through the shared check in `ActionApplier.apply`.
- Toggle: `BehaviorSectionConfig.moveCrossesMonitorAtEdge` (default false), parsed by
  `applyBehaviorKey` with `applyBoolKey`. A non-boolean is a line-numbered config **error**, like
  every other bool key (`focus-follows-mouse`, `maximize-single-window`, ...), not a warning:
  the brief said "warning + default", but the repo's policy (CONTRIBUTING, "Add a config key")
  makes a wrong type an error, and an invalid file keeps the WM on the previous config
  (invariant 9). `ActionApplier.Context.behavior` carries it; with it on, `move-column-left/right`
  go through `moveColumnOrToDisplay`. Settings > Focus > **Displays** card, toggle
  "Move columns across displays at the edge" (`FocusSectionDraft.moveCrossesMonitorAtEdge`,
  `behaviorEdits(..., moveCrossesMonitorAtEdge:)`; `patchGioConfig` keeps comments).
- CLI: `gio move left/right` is the column move (FI-06), so it honours the toggle.
  `CommandSession.displayFrames` (new; empty = unknown, the edge then stops the column) is filled
  by `SessionHost` before every IPC dispatch; the reply on a crossing is
  `moved column to the display on the left|right`. `IPCRouter`'s reflow syncs the shown workspace.
  `gio focus` is unchanged (the toggle is about moving).
- Effects: `.crossedDisplay` sets `syncsShownWorkspace`; all four actions carry a focus intent.
  Motion causes: `.windowMovement` for the two moves, `.viewScroll` for the focus pair (usually a
  scroll; crossing to a display moves no window).
- Bindings: none. niri's default config binds none of the four, and Gio's free combos are not
  niri defaults, so they ship unbound; the default binding count stays 75. Catalog: four entries
  at the end of the Monitors category (20 entries).

### Tasks
- [x] MM-06 — Move Edge actions, landing and toggle. Commit `f8bceec`; LIVE PENDING.
  `GioCore/Hotkeys/HotkeyDispatcher.swift` (4 cases), `ShortcutCatalog.swift`,
  `Config/ConfigParser.swift` (names, behavior key), `Config/GioConfig.swift`,
  `Config/SettingsForms.swift`, `Config/ConfigTemplate.swift`, `Config/AnimationKinds.swift`,
  `Focus/FocusIntent.swift`, `Workspace/WorkspaceManager.swift` (`ColumnLanding` insert),
  `Workspace/MoveEdge.swift` (new), `Commands/CommandDispatcher.swift`,
  `GioSession/Actions/ActionApplier.swift`, `GioDesktop/SessionHost.swift`,
  `GioUI/Settings/FocusSettingsView.swift`, `SettingsPresentation.swift`; docs: README,
  `docs/USER_GUIDE.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md` (check 14c, limitation),
  AGENTS.md, this file.

### Evidence
- RED by compilation (`swift build --build-tests` before production code): `HotkeyAction` has
  no member `moveColumnLeftOrToMonitorLeft` / `moveColumnRightOrToMonitorRight` /
  `focusColumnOrMonitorLeft` / `focusColumnOrMonitorRight`; extra argument `landing`; extra
  argument `moveCrossesMonitorAtEdge`; `BehaviorSectionConfig` has no member
  `moveCrossesMonitorAtEdge`; no `.withinWorkspace` / `.crossedDisplay` / `.unchanged`.
- Tests: `MoveEdgeTests` (13: landing first / last / after-focused; in-strip moves both ways;
  right edge lands first and focus follows; left edge lands last; no neighbour, one display and
  unknown geometry unchanged; empty workspace and up/down unchanged; focus within the strip
  then across both ways; focus without a neighbour unchanged; the target plan reveals the landed
  column both ways; config default / parse / non-boolean error / template; patch keeps comments;
  names, unbound, focus intent, motion causes, 75 bindings; `gio move right` off and on),
  `ActionApplierTests` (6 new: or-monitor actions inside the strip match the plain ones; move
  right crosses and lands first, back left lands last; focus crosses with the empty-display
  warp; no neighbour unchanged; toggle off stops / on crosses for both directions; toggle leaves
  an in-strip move alone), `ShortcutCatalogTests` (Monitors 20, the four unbound),
  `ConfigPatcherTests`, `SettingsPresentationTests`, `ConfigCoordinatorTests`.
- GREEN: `swift test`, all bundles 0 failures: GioUITests 306 (53 skipped), GioSessionTests 399,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 83, GioCoreTests 1685. Signed `xcodebuild` BUILD
  SUCCEEDED. `git diff --check` clean.
- LIVE PENDING (nothing run on real displays; Gio was not launched): `docs/TESTING.md` check 14c.
  With two displays side by side, bind the four actions, cross the edge both ways (lands first
  on the right, last on the left, target scrolls to it, focus and cursor follow), press at the
  outer edge (nothing), then turn on Settings > Focus > Displays > **Move columns across
  displays at the edge** and repeat with `Alt+Shift+H/L` and `gio move right`.

## Progress
- 2026-10-07: MM-01, MM-02 and MM-03 (review fixes) implemented and verified automatically;
  live check pending.
- 2026-10-08: committed as `ecfd426` and pushed to `main`; still not tested on real displays.
- 2026-10-08: MM-04 (live repair after the first two-display session) implemented and verified
  automatically; not committed; live check pending.
- 2026-10-09: MM-04 committed as `e564c8d` and pushed to `main`. LIVE PENDING: hot-plug while running, the 2160x1440 left/above arrangement, Alt+O per display, Move Window to Display.
- 2026-10-11: MM-06 (Move Edge) committed as `f8bceec` on `feat/move-edge` (not pushed, not
  merged) and verified automatically; LIVE PENDING (check 14c).
