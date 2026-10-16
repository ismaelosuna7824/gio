# New window position

## Objective
Let the user choose where a newly opened window's column lands in a scrolling workspace's strip:
right of the focused column, left of it, at the start or at the end (today's behavior), with a
`[layout]` config key and a Settings > Layout picker.

## Problem (code check 2026-10-15, HEAD `1219350`)
- Every arrival appends a new last column: `appendArrivalColumn` (`GioCore/Rules/RulePlacement.swift`)
  does `workspace.columns.append`, called by `placeArrival` (live arrivals and startup scan in
  `DiscoveryService.registerNew`, a tab dragged out in `tabWindowMoved`) and by `applyTitleRecheck`.
- No config key controls it.

## Scope
WP-01..WP-03 below. Not in scope: a per-rule override (`[[window-rules]]`), dwindle placement
(the dwindle tree already splits the focused leaf), changing startup/rescan order.

## Constraints
- `GioCore` stays pure: the position decision is a Core function with tests; `DiscoveryService`
  only passes the configured value.
- Only `WindowReconciler` writes frames: placement changes model state only.
- Default `end` keeps today's behavior byte for byte.
- Invalid value is a config error and never breaks the WM (rule 9); config writes go through the
  patcher.

## Decisions
- **Key:** `[layout] new-window-position`, values `"end"` (default), `"start"`,
  `"right-of-focused"`, `"left-of-focused"`. Core enum `NewWindowPosition` (String raw values,
  `CaseIterable`), stored in `LayoutSectionConfig.newWindowPosition`.
- **Relative to the destination workspace's focused column** (a rule may route the window to
  another workspace or display). An empty strip lands at index 0 for every value.
- **Focus:** an arrival that takes focus becomes the focused column at its index. One that does not
  (`open-focused = false`, floating, minimized) keeps the strip's focused column: its index shifts by
  one when the new column lands at or before it.
- **Scrolling only:** a dwindle workspace keeps appending to the membership list; the tree decides
  geometry (`WorkspaceManager` sync).
- **Live arrivals only:** `registerNew` with `mayFollow == true` and a dragged-out tab use the
  configured value; the startup/rescan scan (`mayFollow == false`) keeps `end` so discovery order is
  stable. The title re-check (moving a live window to its rule's workspace) uses the configured value.
- `placeWindow` (`WindowRules.swift`, TileAssembly) keeps `end`.
- Read at arrival time, so a reload applies at once.

## Tasks
- [x] **WP-01 Core:** `NewWindowPosition`, `LayoutSectionConfig.newWindowPosition`, parser
  (`[layout] new-window-position`, error on unknown value), config template, positioned
  `appendArrivalColumn`/`placeArrival`/`applyTitleRecheck` with tests (each position, focus shift,
  empty strip, dwindle unchanged, parse/invalid/default). Commit `efc8a6c`. Route: delegated
  (writer trigger).
- [x] **WP-02 Session:** `DiscoveryService` passes the configured position for live arrivals and
  dragged-out tabs, `end` for the startup/rescan scan; session tests. Commit `341eb65`.
  Route: delegated (writer trigger).
- [x] **WP-03 Settings and docs:** Settings > Layout picker ("New windows open"), its config edit,
  `docs/USER_GUIDE.md` `[layout]` row and Settings row, `docs/TESTING.md` live-pending line.
  Commit `ac1b60f`. Route: delegated (writer trigger).

## Checks
`swift test` (every bundle, 0 failures), signed `xcodebuild` (GioUI changes), `git diff --check`.
Live behavior (opening apps with each value) is not verifiable by automated tests.

## Routing
Delegated direct: one writer (2+ non-trivial files across GioCore, GioSession, GioUI, docs).

## Progress
- 2026-10-15: document created; WP-01..WP-03 pending.
- 2026-10-15 WP-01 `efc8a6c` `feat(layout): choose where new windows open (WP-01)`: RED
  `swift build --build-tests` failed to compile (`cannot find 'NewWindowPosition' in scope`,
  `extra argument 'position' in call`, no member `newWindowPosition`). GREEN: 6 new
  `RulePlacementTests` (each value with focus taken and kept, empty strip, a rule's other
  workspace, dwindle unchanged, title re-check) and 3 new `ConfigTests` (default, each value, invalid
  value error); `swift test --filter GioCoreTests`: 2027 executed, 0 failures (first run caught a
  test-setup ordering bug in the title re-check test, fixed before commit). The position
  index lives in `NewWindowPosition.insertionIndex`; a non-focusing arrival shifts `focusedColumn`
  only when inserted at or before it in a non-empty strip, so `end` stays byte for byte.
- 2026-10-15 WP-02 `341eb65` `feat(session): open live arrivals at the configured position (WP-02)`:
  `DiscoveryService.Context.newWindowPosition` (default `{ .end }`), wired in `SessionHost` to
  `session.config.layout.newWindowPosition` (read at each arrival) and in the test `EventWorld`.
  RED: with `DiscoveryService.swift` at HEAD the build failed (`extra argument 'newWindowPosition'
  in call`). GREEN: `NewWindowPositionArrivalTests` (live arrival with `right-of-focused` lands
  right of the focused column; a full scan still appends) 2/2; `swift test`: 2975 executed,
  0 failures (53 skipped).
- 2026-10-15 WP-03 `ac1b60f` `feat(settings): pick where new windows open (WP-03)`:
  `LayoutSettingsForm.newWindowPosition` and its edit; the picker sits in Settings > Layout >
  Column Width (the center-focused-column picker lives in the Focus section's Scrolling card, which
  edits `FocusSectionDraft`, not the layout form). RED: with `SettingsForms.swift` at HEAD the build
  failed (the picker's options did not resolve). GREEN: `swift test`: GioPackageTests 2976
  executed, 0 failures (53 skipped); signed `xcodebuild` (scheme Gio): BUILD SUCCEEDED;
  `git diff --check` clean. Live behavior not verified (TESTING.md live-pending line).
- 2026-10-16: the commits had been rebased onto `7794db1` (hashes above are the rebased ones);
  moved off `dev` to `feat/new-window-position` (cut from up-to-date `origin/dev`), `dev` reset
  to `origin/dev`. Not pushed.
- Next: live check per `docs/TESTING.md` (New window position).
