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
WP-01..WP-05 below. Not in scope: a per-rule override (`[[window-rules]]`), dwindle placement
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
  empty strip, dwindle unchanged, parse/invalid/default). Commit `b41c5e7`. Route: delegated
  (writer trigger).
- [x] **WP-02 Session:** `DiscoveryService` passes the configured position for live arrivals and
  dragged-out tabs, `end` for the startup/rescan scan; session tests. Commit `006e488`.
  Route: delegated (writer trigger).
- [x] **WP-03 Settings and docs:** Settings > Layout picker ("New windows open"), its config edit,
  `docs/USER_GUIDE.md` `[layout]` row and Settings row, `docs/TESTING.md` live-pending line.
  Commit `657de7c`. Route: delegated (writer trigger).
- [x] **WP-04 Open lag mid-strip (live report 2026-10-16):** with `right-of-focused`, a new
  window is visible in its tile only ~400–560 ms after registration although its frame is written
  at +5–32 ms. Cause (log 19:18–19:19Z, Notes 32798:14/32892:15/33263:16): the insert moves a
  neighbour that has a cached image, so the pass is a snapshot flight; the new window has no
  image yet and becomes a hole (`planSnapshotFlight`), and holes only cut the backdrop
  (`SnapshotOverlay.cut`), so the neighbour's image layer starts over the new slot and covers the
  already placed window until it slides off (`anim done duration=362/393ms`, `snapshot holes
  ids=1`). Fix: the hole of a window opening in this pass also cuts through the image layers, for
  the whole flight and its retargets, so the new window shows at once and the neighbours slide out
  from under it. Undrawn windows keep no hole (SM-31); the paint check on holes stays. Route:
  delegated (writer trigger). Commit `55d5f88`.
- [x] **WP-05 Niri-like open: hidden until redrawn, then pop in (live report 2026-10-16/17):**
  after WP-04 the new window shows at once, but the user sees the app redraw at its new size
  (Notes: `paint check ms=157`, `handoff waited ms=73`, log 20:20:14Z). Niri never shows a window
  before its first frame at the configured size (initial configure, unmapped until the first
  buffer) and pops it in with a short `window-open` animation. macOS has no initial configure, so
  Gio hides the redraw instead: with the snapshot renderer, an opening visible tiled window's slot
  stays covered (no hole) while it redraws at its target; once a capture at the target size is
  not blank, its image rises `offset` points and fades in over the `window-open` animation, then
  the real window is revealed. A bounded wait (no confirmed paint in time) reveals it as today.
  Applies to mid-strip flights and to open passes where nothing else moves. AX renderer and
  windows that are not shown keep today's behavior. Rebased onto `origin/dev` `68ada7e` first
  (WP hashes changed again). Route: delegated (writer trigger). Commit `cc52ff7`.

## Checks
`swift test` (every bundle, 0 failures), signed `xcodebuild` (GioUI changes), `git diff --check`.
Live behavior (opening apps with each value) is not verifiable by automated tests.

## Routing
Delegated direct: one writer (2+ non-trivial files across GioCore, GioSession, GioUI, docs).

## Progress
- 2026-10-15: document created; WP-01..WP-03 pending.
- 2026-10-15 WP-01 `b41c5e7` `feat(layout): choose where new windows open (WP-01)`: RED
  `swift build --build-tests` failed to compile (`cannot find 'NewWindowPosition' in scope`,
  `extra argument 'position' in call`, no member `newWindowPosition`). GREEN: 6 new
  `RulePlacementTests` (each value with focus taken and kept, empty strip, a rule's other
  workspace, dwindle unchanged, title re-check) and 3 new `ConfigTests` (default, each value, invalid
  value error); `swift test --filter GioCoreTests`: 2027 executed, 0 failures (first run caught a
  test-setup ordering bug in the title re-check test, fixed before commit). The position
  index lives in `NewWindowPosition.insertionIndex`; a non-focusing arrival shifts `focusedColumn`
  only when inserted at or before it in a non-empty strip, so `end` stays byte for byte.
- 2026-10-15 WP-02 `006e488` `feat(session): open live arrivals at the configured position (WP-02)`:
  `DiscoveryService.Context.newWindowPosition` (default `{ .end }`), wired in `SessionHost` to
  `session.config.layout.newWindowPosition` (read at each arrival) and in the test `EventWorld`.
  RED: with `DiscoveryService.swift` at HEAD the build failed (`extra argument 'newWindowPosition'
  in call`). GREEN: `NewWindowPositionArrivalTests` (live arrival with `right-of-focused` lands
  right of the focused column; a full scan still appends) 2/2; `swift test`: 2975 executed,
  0 failures (53 skipped).
- 2026-10-15 WP-03 `657de7c` `feat(settings): pick where new windows open (WP-03)`:
  `LayoutSettingsForm.newWindowPosition` and its edit; the picker sits in Settings > Layout >
  Column Width (the center-focused-column picker lives in the Focus section's Scrolling card, which
  edits `FocusSectionDraft`, not the layout form). RED: with `SettingsForms.swift` at HEAD the build
  failed (the picker's options did not resolve). GREEN: `swift test`: GioPackageTests 2976
  executed, 0 failures (53 skipped); signed `xcodebuild` (scheme Gio): BUILD SUCCEEDED;
  `git diff --check` clean. Live behavior not verified (TESTING.md live-pending line).
- 2026-10-16: the commits had been rebased onto `7794db1`; moved off `dev` to
  `feat/new-window-position` (cut from up-to-date `origin/dev`), `dev` reset to `origin/dev`.
  Not pushed.
- 2026-10-16 WP-04 `55d5f88` `fix(snapshot): show an opening window above the images it displaces (WP-04)`:
  `SnapshotHole.entry`; `planSnapshotFlight`/`snapshotHoles(opening:)` mark the hole of a window
  opening in the pass (NA-02 entry) as an entry hole; `SnapshotFlightController.drive(entries:)`
  (`SessionHost` passes `pass.entries`) keeps the flight's opening set across retargets (a window
  that gains a layer loses its hole as before) and hands `entryHoles` to `OverlayPort`;
  `OverlayHoles` (GioCore, `backdrop` = every hole, `images` = entry holes, sorted by id) reaches
  `SnapshotOverlay`, whose window layers now hang in one container (`windowLayer`) masked with
  `overlayBackdropMask` at the entry holes; the backdrop mask is unchanged. Undrawn windows keep
  no hole; the paint check on holes is unchanged. Debug `snapshot holes ids=N entries=E`.
  RED: `swift build --build-tests` failed to compile (`cannot find 'OverlayHoles' in scope`,
  `extra argument 'opening'/'entry'/'entries' in call`, `FakeOverlay` does not conform to
  `OverlayPort`). GREEN: 5 new `SnapshotFlightPlanningTests` (opening imageless window is an entry
  hole, non-opening stays ordinary, undrawn opening window has no hole, retarget keeps then drops
  the entry hole, `OverlayHoles` split) and 3 new `SnapshotFlightTests` (entry hole from the prime
  and paint-checked, kept on a retarget, undrawn opening window has none); `swift test`: 2991
  executed, 0 failures (53 skipped); signed `xcodebuild` (scheme Gio): BUILD SUCCEEDED;
  `git diff --check` clean. Not unit-tested (compile-checked): the `CALayer` container and its
  mask. Live behavior not verified (TESTING.md live-pending line). Route: delegated (writer
  trigger).
- 2026-10-17: the branch was rebased onto `origin/dev` `68ada7e`; the hashes above are the
  rebased ones (WP-01 `b41c5e7`, WP-02 `006e488`, WP-03 `657de7c`, WP-04 `55d5f88`; record commits
  `af4fbb6`, `35d42a2`, `0697f42`). Not pushed.
- 2026-10-17 WP-05 `cc52ff7` `feat(snapshot): hide an opening window until it has redrawn, then pop it in (WP-05)`:
  Core `GioCore/Snapshot/WindowOpenPop.swift`: `WindowOpenPop` (the rise from the NA-02 entry start
  to the target on the resolved window-open spring or ease-out, opacity = the rise's progress,
  `watchdogLimit`), `windowOpenPopKeyframes`, `WindowOpenPopPlan`/`planWindowOpenPops` (entries
  and their start frames when `window-open` is active), `WindowOpenPopBook` (cover, capture
  verdicts, `maxWait` 0.4 s, `firstCaptureDelay` 0.05 s, `retryInterval` 0.04 s, expiry reasons
  `timeout|blank|noCapture`, `retarget`, `abort`) and the debug lines `snapshot open pop id=P:E
  waited ms=N` / `snapshot open reveal id=P:E reason=...`; `planSnapshotFlight(covered:)` and
  `SnapshotFlightDecision.snapshot(covered:)` (no layer, no hole, display animated, so an open alone
  is an overlay flight). Session `SnapshotFlightController.drive(pops:)`: covers at the pass, first
  capture after the writes (SM-30 `captureFresh` + `snapshotFreshVerdict`), pop through
  `OverlayPort.popFlight` (image cached with `storeFresh`), reveal through `revealFlight` (entry
  hole), deferred `handOver` until no window is covered, retarget reveals moved windows, every
  abort path clears with `reason=abort`; covered windows are not paint-checked. GioUI
  `SnapshotOverlayController.pop`/`reveal` (a `WindowLayers` per pop, keyframed position and
  opacity, the flight's ring and dim, watchdog re-armed); `SessionHost` builds the plan and wires
  `overlayPop`/`overlayReveal` (`main.swift`). RED: `swift build --build-tests` failed to compile
  (`cannot find 'planWindowOpenPops'`/`'WindowOpenPop'`/`'WindowOpenPopBook'`/`'WindowOpenPopPlan'
  in scope`, `cannot infer contextual base in reference to member 'noCapture'`). GREEN: 18
  `WindowOpenPopTests` (covered vs hole, entry-only flight, no backdrop, parked/undrawn never
  covered, pop plan, spring and ease-out timelines, keyframes, watchdog, wait verdicts and
  reasons, retarget, log lines) and 13 new `SnapshotFlightTests` (covered at the prime, confirmed
  capture pops then reveals and hands over, partial read retried, timeout reveals without the pop,
  abort mid-wait, end mid-pop, failed prime, retarget moving or keeping the target, entry-only via
  the overlay, alone on its display, no backdrop and no plan keep AX); `swift test`:
  GioPackageTests 3051 executed, 0 failures (53 skipped); signed `xcodebuild` (scheme Gio): BUILD
  SUCCEEDED; `git diff --check` clean. Not unit-tested (compile-checked): the pop's `CALayer`
  keyframes and the watchdog re-arm. Live behavior not verified (TESTING.md live-pending line).
  Route: delegated (writer trigger).
- Next: live check per `docs/TESTING.md` (New window position, New window lag mid-strip, New
  window hidden until redrawn).
