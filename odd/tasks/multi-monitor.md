# Multi-monitor: correct foundations, then niri monitor actions

## Objective
Two or more displays must behave correctly: frames flip with the right height, displays have
a geometric order, startup windows stay on their display, each display hides and switches
its own workspaces, and default-width columns fit their own display (MM-01). Niri monitor
actions (`focus-monitor-*`, `move-column-to-monitor-*`, `move-window-to-monitor-*`,
`move-workspace-to-monitor-*`) follow in MM-02.

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

## Progress
- 2026-10-07: MM-01, MM-02 and MM-03 (review fixes) implemented and verified automatically;
  live check pending.
- 2026-10-08: committed as `ecfd426` and pushed to `main`; still not tested on real displays.
