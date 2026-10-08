# Workspace overview and Mission Control

## Objective
Give the user a usable view of every Gio workspace. macOS Mission Control (Control+Up)
shows Gio's windows as tiny thumbnails; Gio gets its own niri-style overview and the
Mission Control workaround is documented.

## Problem (2026-10-07, user screenshot)
Mission Control lays out every window of the Space from its real frame. Gio parks
off-viewport columns at the side edges and hidden workspaces at the bottom corner with a
1 pt sliver (`ParkingPlanner.swift`), so Mission Control scales everything down to fit
those frames. There is no public API to change Mission Control's layout. AeroSpace
documents the same symptom and the workaround "Group windows by application"
(https://github.com/nikitabobko/AeroSpace/blob/main/docs/guide.adoc#a-note-on-mission-control).

## Scope (user choice 2026-10-07: "Ambos")
1. Document the workaround (USER_GUIDE concepts, TESTING known limitations).
2. WO-01: Gio's own overview, niri `toggle-overview`: hotkey, config action, CLI verb, panel.
Out of scope: floating windows in the overview, live updates while it is open, drag and
drop between workspaces, other displays' stacks (the overview shows the focused display).

## Decisions
- `toggle-overview` is a real `HotkeyAction` (configurable, default `Alt+O` like niri's
  `Mod+O`) that the app handles: `SessionHost.handleCombo` hands it to the main thread
  before the action table; `ActionApplier` keeps it as a no-op (exhaustive switch),
  `motionCause` is `.passive`, no focus intent.
- `gio overview` (`CLICommand.toggleOverview`) reaches the same hook through
  `IPCRouter.Context.toggleOverview`.
- Data: `SessionFactsBuilder.workspaceOverview()` builds one `WorkspaceStripFact` per
  workspace of the focused display (same layout math as the DD-02 miniature), on demand,
  not on every publication.
- Thumbnails: one `SnapshotCapturer` capture of the windows' physical frames (parked ones
  included), no backdrop, scale capped at 0.75, 1.5 s budget. Without Screen Recording or
  before macOS 14 the tiles show the app icon.
- Selection is pure in Core (`WorkspaceOverviewFacts.selection(_:stepping:)`): left/right
  walk reading order, up/down land on the window nearest the same on-screen place, edges
  stop, an empty workspace is selectable as a whole.
- A pick closes the panel first, then `focusWindow` (window; launcher path) or
  `apply(.workspace(n))` (empty workspace or digit). A window that vanished falls back to
  its workspace.
- Presentation reuses `LauncherLifecycle` (toggle reads the real panel, resign-key grace,
  generation tokens).

## Constraints
AGENTS.md hard rules: no AX outside the reconciler path (the overview only reads session
state and captures images), Gio's own panel is never managed (pid guard), logs carry no
window titles (titles appear only in the panel).

## Tasks
- [x] WO-00 — Mission Control workaround documented (`docs/USER_GUIDE.md` concepts,
  `docs/TESTING.md` known limitations). Commit `2aa79b6`.
- [x] WO-01 — Workspace overview. Commit `2aa79b6`.
  Core: `HotkeyAction.toggleOverview`, `Alt+O`, `toggle-overview` config name, catalog
  entry, `CLICommand.toggleOverview` (`gio overview`), `WorkspaceOverview.swift`.
  Session: `SessionFactsBuilder.workspaceOverview()`, `IPCRouter` hook, `ActionApplier`
  no-op. UI: `WorkspaceOverviewModel.swift`, `WorkspaceOverviewPanel.swift`. Host:
  `onToggleOverview`, `workspaceOverview`, `captureOverviewThumbnails`, `focusWorkspace`.
- [x] SW-01 — A single window fills the strip (user request 2026-10-07: "si en el workspace
  solo está una ventana siempre tiene que ser como se ve con alt+f"). Commit `a179695`.
  `[layout] maximize-single-window` (bool, default `true`) → `LayoutConfig.maximizeSingleWindow`;
  `ScrollableLayoutEngine` lays a strip of exactly one window (one column, one window, after
  `tilingWorkspace` drops floating ones) at proportion 1 without touching `widthSpec`, so a
  second window restores the widths. Native zoom is unaffected (`notGrowing`). Settings >
  Layout toggle "Full width when alone" (`LayoutSettingsForm.maximizeSingleWindow`).
  Evidence: RED (no `maximizeSingleWindow` argument / member); GREEN
  `MaximizeSingleWindowTests` (6); `swift test` all bundles 0 failures (Core 1264, Session
  272, UI 249/53 skipped, MacOS 40, Mac 19, POC 7); throwaway `planDisplayLayout` smoke on a
  1512 pt viewport: one window `(8, 8, 1496, 928)`, two windows `744` each. LIVE PENDING.
- [x] LA-01 — Launcher crash froze Gio (live report 2026-10-07: a new window did not tile and
  no Gio hotkey worked). Commit `ffd4a9e`. Cause, from the unified log of Gio pid 23696 at
  18:02:08: `NSInternalInconsistencyException` in `-[NSWindow _reallySetFrame:]`, frame
  `{{580, 3.06e59}, {640, 469}}`, from `LauncherPanel.setFrame` called by
  `LauncherPanelController.show` through `panel.animator().setFrame`. On the Swift subclass
  the override ran with the `_NSWindowAnimator` proxy as `self` and read `anchoredTop` from
  the proxy's memory (probe: `self` class `_NSWindowAnimator_…`, a nil property read as
  `Optional(0.0)`). Under the debugger the app stopped at the exception, so the session
  stopped tiling and the tap stopped handling keys. Latent since FI-09; not caused by SW-01
  or WO-01. Fix: `LauncherPanel.animateFrame(to:)` reaches the proxy as `NSWindow`
  (Objective-C dispatch). RED: `LauncherPanelAnimationTests` landed at `(300, -469)`
  instead of `(300, 400)`; GREEN; `swift test` all bundles 0 failures (UI 250/53 skipped,
  Session 272, POC 7, Mac 19, MacOS 40, Core 1264); signed build SUCCEEDED. LIVE PENDING:
  open the launcher with `Alt+Space` on the signed app.

## Evidence (WO-01)
- RED: `swift test --filter GioCoreTests...` failed to compile (`CLICommand` has no member
  `toggleOverview`); `IPCRouterTests` (extra argument `toggleOverview`);
  `SessionFactsBuilderTests` (no member `workspaceOverview`); `WorkspaceOverviewModelTests`
  (types missing).
- GREEN: `swift test`, every bundle 0 failures: GioUITests 249 (53 skipped, opt-in
  snapshots), GioSessionTests 272, GioPOCTests 7, GioMacTests 19, GioMacOSTests 40,
  GioCoreTests 1258.
- New tests: `WorkspaceOverviewTests` (7), `WorkspaceOverviewModelTests` (7),
  `HotkeyTests.testOverviewDefaultsToAltOLikeNiri`,
  `ActionApplierTests.testOverviewLeavesTheSessionUntouched`,
  `IPCRouterTests.testOverviewHandsTheToggleToTheApp`,
  `SessionFactsBuilderTests.testOverviewLaysOutEveryWorkspaceOfTheFocusedDisplay` and
  `testNoOverviewWithoutTheFocusedDisplay`.
- Visual: the real `WorkspaceOverviewView` rendered offscreen (throwaway test, removed)
  with three workspaces, stacked column, parked column, fake thumbnails: rows, labels,
  selection ring, captions and the empty workspace drew as intended.
- Signed build: `xcodebuild -scheme Gio ... -derivedDataPath .build/GioAutoTeam` BUILD
  SUCCEEDED.
- LIVE PENDING: Alt+O on a real desktop (panel on the focused display, key routing,
  resign-key dismissal, thumbnail capture of parked windows, pick focusing the window),
  `gio overview` over IPC, multi-display placement.

## Progress
- 2026-10-07: diagnosis, workaround docs, WO-01 implemented and verified (automated,
  signed build, offscreen render). Live check pending.
