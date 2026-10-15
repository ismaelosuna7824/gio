# Window coverage (phase 1 of live-issues plan)

## Objective
Every normal window on the active display gets managed by Gio: tiled when it can be
resized, visibly tracked as floating (with a reason) when it cannot. No window stays
silently untiled, and apps/windows opened after startup join the layout immediately.

## Problem (diagnosis 2026-09-29, engram "Gio live issues diagnosis")
- `WindowDiscovery.swift:59,116-128` accepts only `AXStandardWindow`; Electron/Java/Qt
  windows with nonstandard/empty subroles and dialogs are dropped uncounted.
- Non-resizable windows fail `axIsTileable` and are omitted from `modes`
  (`SessionHost.swift:255-266`) with no trace.
- No `NSWorkspace.didLaunchApplication` observer: new apps join only when activated,
  via a 0.3s debounced full rescan that tears down every observer.
- Windows created after the observer was built get no per-window destroyed/moved
  notifications; closed windows linger until their process dies.
- Windows minimized at startup are skipped and never picked up; rules are evaluated
  only at registration.

## Why
User report: "cuando hace el tiling no lo hace para todas las ventanas abiertas,
algunas aun se quedan flotando". User approved phase 1 first (2026-09-29).

## Scope (authorized)
Window admission, observation and registration only. Out of scope: animation/perf
(phase 2/4), unified desktop app (phase 3). Other Spaces stay a documented limit.

## Constraints
- Pure decision logic lives in GioCore/GioMacOS with Swift Testing coverage; GioDesktop
  (no test target) only wires it. Only `WindowReconciler` moves windows.
- Commits: Conventional Commits, NO Co-Authored-By / AI attribution (user rule).
- Directory has a trailing space; quote paths.

## Tasks
- [x] WC-01 — Admission classifier: pure `WindowAdmission` (role/subrole/settable/
  fullscreen/minimized -> tile | float(reason) | ignore(reason)); standard + unknown
  resizable subroles tile, dialogs/floating/non-resizable float, sheets/popovers ignore.
  Discovery reports every exclusion with a reason.
  DONE `6cfa1db`: 13 tests (RED 11/13 on stub -> GREEN), swift test 210 executed 0 failures, signed Gio build OK, diff --check clean. Added `.suspend(fullscreen|minimized)` outcome; discovery result gains `floating`/`ignored`. Review: assess UNAVAILABLE (gentle-ai trims trailing-space repo path: lstat .../gio not found) -> treated as due, pending user decision.
- [x] WC-02 — Floating is managed, not omitted: non-tileable windows register as
  floating with a reason; tileability cached per window (re-probed on resize/
  attribute events, not every reflow); `list-windows`/status expose mode + reason.
  DONE `d763b75`: 15 tests (RED compile-fail -> GREEN), 225 executed 0 failures (parent spot-check re-ran), signed build OK. Fixed latent bug: probe-failing windows were missing from `modes` and thus laid out anyway. Gap: cache is invalidateAll on every resyncAndReflow (every AX event) — refine per-window in WC-04; ignored/suspended not exposed in status. Review: UNAVAILABLE (gentle-ai trailing-space path defect; user chose continue without reporting).
- [x] WC-03 — Incremental app observation: launch/terminate observers attach/detach one
  pid's AX observer and register/reap its windows without a full teardown.
  DONE `e9c8066`: pure ObservationBook (10 tests RED compile-fail -> GREEN), 235 executed 0 failures, signed build OK. Fixed latent bug: rebuilt observers were attached to the session queue's run loop (never ran); now always main run loop. Review: UNAVAILABLE (gentle-ai path defect, user chose continue).
- [x] WC-04 — Per-window observers for windows created after startup (destroyed/moved/
  resized/minimized/deminimized); destroyed windows leave the layout immediately.
  DONE `695ac17`: typed events with pid+element, WindowEventPolicy/WriteEchoGate (20 tests RED -> GREEN), 255 executed 0 failures (parent spot-check), signed build OK. Tileability invalidateAll only on permission regain. AX wiring compiled only, LIVE PENDING. Review: UNAVAILABLE.
- [x] WC-05 — Minimize lifecycle: minimized windows stay registered but out of layout;
  deminimize re-inserts; rules re-evaluated on config reload. Added 2026-09-29 (WC-04 gap):
  full rescans also purge registered windows of a scanned pid that no longer appear
  (fallback when destroyed-element CFEqual matching fails).
  DONE `b7fb956`: isMinimized flag, pure minimize/restore, reevaluateRules, vanishedWindowIDs gated by completePIDs (29 tests RED compile-fail -> GREEN), 284 executed 0 failures (parent spot-check), signed build OK. Gaps: no workspace reassignment on reload; manual tile vs float rule not tracked; deminimize doesn't switch workspace; a registered window newly classified `ignore` gets purged. Review: UNAVAILABLE.
- [x] WC-06 — Park off-viewport columns (added 2026-09-29 from live run, user approved):
  live log showed each reflow moved only the 2-3 visible windows; `splitVisibleFrames`
  drops off-viewport frames, so those windows keep stale frames and stack behind the
  visible columns. Park them nearly fully off-screen (1px visible) on the side they
  belong to (left columns -> left edge, right columns -> right edge), AeroSpace-style,
  avoiding edges shared with another display (fallback bottom-right corner); parked
  frames verified with tolerance, never raised/focused.
  DONE `3a30bbe`: pure planParking (full display frame, Cocoa coords), reconciler accepts clamped parked landing (<=40pt strip) then `already`; 18 tests RED -> GREEN, 302 executed 0 failures (parent spot-check), signed build OK. LIVE PENDING: does macOS accept the 1pt strip. Review: UNAVAILABLE.
- [x] WC-07 — Click focus without re-layout storm (live run 2026-09-29): every click
  (focus/activation event) triggers a debounced FULL rescan that rewrites all windows
  (`reflow applied=2 parked=8 already=0`), moving windows under the cursor so they can't
  be selected/dragged. Adopt focus from the focused-window event on a light path (no
  rescan), never move windows while a mouse button is down (defer until release), and
  make a rescan not invalidate the reconciler's view of already-parked windows.
  DONE `4a6351b`: root cause = rescan adopted the LAST enumerated app's AXFocusedWindow (every app reports one) -> focus jumped to an arbitrary column -> reveal scrolled the strip -> all windows rewritten. Now frontmost app only; focus events on light path (.adoptFocus); ReflowDeferral waits while mouse is down. 13 tests RED -> GREEN, 328 executed 0 failures. LIVE PENDING. Review: UNAVAILABLE.
- [x] WC-08 — Restore windows when Gio exits (regression from WC-06): on Quit/terminate
  and SIGTERM/SIGINT/SIGHUP, bring every parked window back fully on-screen; on startup,
  parked leftovers are recovered by the initial layout; a no-daemon recovery command
  (`gio-poc restore`) covers SIGKILL (e.g. Xcode Stop).
  DONE `cb1781f`: pure planRestore (cascade 32pt), reconciler restoreOffscreen, SessionHost.shutdown on terminate + SIGTERM/INT/HUP, startup restore of off-screen non-tiled, `gio-poc restore` + `gio-poc-restore` scheme. 13 tests RED -> GREEN, 315 executed 0 failures. LIVE PENDING. Review: UNAVAILABLE.
- [x] WC-09 — Stale focus on click (live retest 2026-09-29): restore on Quit works
  (`restore applied=9`), but some clicks still produce `reflow applied=2 parked=8
  already=0` with no hotkey and no clamps -> viewport jumps to a far column. Hypothesis:
  activation arrives before the app's AXFocusedWindow updates, so a stale (parked) window
  is adopted. Fix: log focus adoption (source, id, column, scroll), and for mouse-driven
  focus adopt only a window containing the click point after the focus settles.
  DONE `9d25405`: FocusSettle (mouse-down via existing tap, settle 80ms, click-point validation, one re-read then drop, coalesce), single requestFocusAdoption entry, `focus adopt`/`focus dropped` debug logs. Code confirmed double adoption per click + unchecked AXFocusedWindow read; stale read itself LIVE PENDING. 15 tests RED -> GREEN, 343 executed 0 failures (parent spot-check). Review: UNAVAILABLE.
- [x] WC-10 — Reveal geometry (live retest 2026-09-29 with WC-09 logs): no `focus dropped`,
  adopted windows were the clicked visible ones, yet `scroll=1824->0`, `1816->916`, `0->16`.
  Root causes: (1) `revealOffset` compared screen-space frames with the content-space
  offset; (2) fraction widths ignored padding/gap so two 0.5 columns overflowed by 16pt.
  DONE `592c89d` (route: inline, 3 source files, understood fix): content-space conversion +
  `proportionalColumnWidth` (Niri semantics). 4 tests RED with the live numbers -> GREEN;
  347 executed 0 failures; signed build OK; diff --check clean. Review: UNAVAILABLE.
- [x] WC-11 — Native window tabs (2026-10-14, user report "las pestañas se sobrelapan"; no
  logs): every macOS tab (Ghostty, Terminal, Finder, TextEdit, Xcode) is its own settable
  `AXStandardWindow` at the group's frame and a fresh `kAXWindowsAttribute` read lists only
  the front tab. Gio had no tab handling: Cmd+T added a column, a background tab left an
  empty-looking slot, a tab switch showed the selected tab over the neighbour column and
  Gio wrote it back to its own column (the window hopped), complete scans (startup,
  resync, SM-31 vanish scans) purged background tabs, and tabs present at startup became
  new columns on first focus.
  DONE (`8effe33`): pure `TabGroupBook` + `tabGroupToJoin` / `tabMemberLeaves` /
  `handOverTabSlot` (`GioCore/Window/TabGroups.swift`). Decision: one slot per group, held
  by the front tab; background tabs stay registered but belong to **no workspace** (not
  the minimized model of column membership plus filtering: nothing to filter in ~25
  `isMinimized` sites, and column/workspace/display moves and dwindle carry the group with
  its one member). Join (`DiscoveryService.registerNew`, every entry point): arrival listed,
  same-pid sibling unlisted at the same frame within 1 pt (a group is listed when its front
  is), facts = one fresh list (`axWindowElements(pid:)`, or the scan's own list) plus AX
  frames of unlisted siblings only; the arrival takes the slot in place (column position,
  height weight, focus, dwindle leaf) with the slot's mode, no enter motion, no rule
  placement or title re-check; two listed windows never merge. Switch: focus adoption of a
  background tab (`FocusCoordinator.adoptResolved` -> `bringTabToFront`) hands it the slot,
  drops its trust and reflows, so only it is written. Leave: a closed front tab hands the
  slot to the next member (join order) before the purge strips it; a background tab's move
  that matches another member's frame is dropped (no trust loss, no reflow); a member
  listed together with another member at a different frame (dragged out) leaves and is
  placed as an arrival; a front tab moving with its group snaps back as before. Complete
  scans (incl. SM-31 `noteSettled`) never purge the members of a group with a listed
  member and heal a missed switch (exactly one listed member); the vanish scan also
  reflows when only the workspaces changed. Deminimizing a background tab opens no column;
  exit restore skips background tabs. Logs: `tab joined id= group= front=`, `tab front id=`,
  `tab left id= reason=closed|draggedOut` (ids only). Not implemented (documented in
  ARCHITECTURE and the user guide): Merge All Windows of already-managed windows (different
  frames), tab bar order. Background tabs still appear in `list-windows`/Overview facts
  without a workspace.
  RED: `swift test --filter GioCoreTests.TabGroupTests` compile failure (no `TabGroupBook`,
  `tabGroupToJoin`, `tabMemberLeaves`, `TabHandover`, `TabMemberFact`, `handOverTabSlot`);
  `swift test --filter GioSessionTests.NativeTabTests` compile failure, then with the
  context seams and stub `isBackgroundTab`/`bringTabToFront` `Executed 11 tests, with 29
  failures` (Cmd+T: columns `[[7:1], [8:2], [7:3]]`, background tab laid out at x=1800,
  background moves scheduled reflows, rescan purged the background tab); after rebasing on
  SM-31 `Executed 13 tests, with 1 failure` (vanish scan healing a switch did not reflow).
  GREEN: `swift test --filter GioCoreTests.TabGroupTests` `Executed 17 tests, with 0
  failures`; `swift test --filter GioSessionTests.NativeTabTests` `Executed 13 tests, with 0
  failures`; `swift test --filter "GioCoreTests\.(TabGroupTests|MinimizeLifecycleTests|DwindleMembershipTests|FocusAdoptionTests|WorkspaceManagerTests|RulePlacementTests)|GioSessionTests\.(NativeTabTests|DiscoveryServiceTests|WindowEventRouterTests|FocusCoordinatorTests|VanishedWindowScanTests|RegistrationRetryGuardTests|WindowOpenArrivalTests|ForeignSpaceDiscoveryTests|RichRuleArrivalTests|FloatingArrivalFocusTests|NamedWorkspaceRoutingTests|DeferredFollowTests)|GioMacOSTests"`
  GioCoreTests `Executed 124 tests, with 0 failures`, GioSessionTests `Executed 135 tests,
  with 0 failures`, GioMacOSTests `Executed 95 tests, with 0 failures`; `swift build` OK;
  `git diff --check` clean. Full suite and signed build: integrator.
  LIVE PENDING (TESTING.md row 1b), log level `info`: (1) Ghostty and Terminal `Cmd+T`
  twice: no new column, `tab joined`; (2) switch tabs by click and `Cmd+Shift+]`: the window
  never hops or covers its neighbour, one `tab front` per switch; (3) `Cmd+W` on the shown
  tab: the tile keeps the tab macOS shows, `tab left ... reason=closed` + `tab front`; close
  a background tab: only `tab left`; (4) drag a tab out: own column, `tab left ...
  reason=draggedOut`, the old window keeps its tile; (5) quit Gio with a two-tab window,
  start, click the other tab: `tab joined`, no column; (6) two separate Terminal windows at
  the same frame stay two columns. [INFERENCE, to confirm live: macOS sends created and
  focused-window events for tabs, lists the new tab at creation time, keeps background tabs
  at the group frame when the front is written.]
- [x] WC-12 — Keyboard focus skips non-tiled columns (2026-10-14, user report: focus
  left/right needed several presses to reach or leave a window). Live state: workspace 1
  had 13 columns but only 7 held tiled windows; the other 6 were Safari `mode=floating
  reason=dialog` windows (84x77, off-screen at y=-17), one column each. Root cause: by
  design a floating or minimized window keeps its own column in `Workspace.columns`;
  layout, gestures, reveal and centering drop them through `tilingWorkspace`, but keyboard
  navigation never filtered: `moveFocus` left/right was a bare `focusedColumn ± 1`,
  `focusColumnFirst`/`focusColumnLast` took the strip ends, and `focusNeighbour` (CLI
  `gio focus`, `focus-column-or-monitor-*`, `focus-window-or-workspace-*`) handed the strip
  to `moveFocus` without modes, so each invisible column cost one keypress.
  DONE (`19bddce`, route: delegated writer, 2+ non-trivial files across GioCore +
  GioSession). Decision: `moveFocus(in:direction:modes:)`, `focusColumnFirst(in:modes:)`
  and `focusColumnLast(in:modes:)` take a required mode map (no default, so no caller keeps
  the bug silently) and skip every column whose windows are all non-tiled; the predicate is
  `isTiled(_:modes:)`, extracted from `tilingWorkspace` (unknown ids count as tiled, so an
  empty map is the old behaviour). Empty columns stay reachable; with no navigable column
  that way the workspace comes back unchanged, so `focus-column-or-monitor-*` crosses to
  the next display and a move from a float column lands on the nearest tiled one.
  Vertical moves and dwindle are unchanged. Callers: `ActionApplier` passes
  `context.modes()` (minimized mapped to non-tiled) to focus left/right/up/down,
  first/last, and a `DwindleGeometry` with those modes to the scrolling
  `focusColumnOrDisplay`; `focusNeighbour` uses `geometry().modes` (the dispatcher's
  `CommandSession.dwindleGeometry` already carries the registry modes).
  RED: `swift build --build-tests` compile failure (`extra argument 'modes' in call`,
  `cannot find 'focusColumnFirst(in:modes:)' in scope`) after the new tests in
  `FocusNavigationTests` (float/minimized skip, only floats ahead = no-op, from a float
  column, empty columns, empty map), `ColumnNavigationTests` (first/last skip end floats),
  `MoveEdgeTests` (a float column at the edge no longer blocks crossing displays) and
  `ActionApplierTests` (focus left/right and `focus-column-or-monitor-left` use
  `context.modes()`; focus actions now probe modes once).
  GREEN: `swift test --filter "GioCoreTests.(FocusNavigationTests|ColumnNavigationTests|MoveEdgeTests|DwindleActionsTests)|GioSessionTests.ActionApplierTests"`
  0 failures; full `swift test` `Executed 2890 tests, with 53 tests skipped and 0 failures`
  (single `GioPackageTests.xctest`); per bundle via `--filter "^<Bundle>\."`: GioCoreTests
  1978, GioSessionTests 481, GioUITests 310 (53 skipped), GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 95, all 0 failures; `swift build` OK; signed `xcodebuild` Gio scheme
  `BUILD SUCCEEDED`; `git diff --check` clean.
  LIVE PENDING: not verified on the live desktop; with the Safari dialog floats present,
  one Alt+H/L per tiled column and `focus-column-or-monitor-*` crossing past a float at
  the strip edge are still to confirm.
- [x] WC-13 (`f43daad`) — A Dock click reveals the app's window on its workspace (2026-10-15,
  user request "si le damos click a las apps de abajo nos lleve al workspace en el que está y
  haga el focus"). The reveal already existed for activations (`revealOnOtherWorkspace`), but
  the live log showed `focus dropped source=activation id=1528:3 frame=1799,-1073 ...
  click=912,44 reason=focused window not under click`: the user's Dock auto-hides
  (`com.apple.dock autohide = 1`), so a Dock click lands inside the display's usable area,
  counted as a window click, and the parked window on another workspace was not under it.
  Decision: the session classifies every click with one WindowServer query before the
  activation it causes arrives (`FocusCoordinator.recordClick` hop; `clickIsOnSystemUI`,
  pure: the frontmost window under the point, Gio's own click-through panels aside, at the
  Dock's layer 20 or above); a click on the Dock or the menu bar is no window click
  (`MouseClick.onSystemUI`, `windowAreaClick`), so the activation adopts at once and reveals.
  The desktop (negative layers) and app panels below the Dock stay window clicks, so a
  desktop click activating Finder still reveals nothing. Debug `focus click on system UI`.
  RED (compile): `FocusSettleTests.testAClickOnSystemUIInsideTheVisibleAreaIsNotAWindowClick`,
  `testSystemUIIsTheDockLayerAndAboveSkippingGiosOwnPanels` and
  `FocusCoordinatorTests.testADockClickRevealsTheActivatedAppsWindowOnItsWorkspace`. GREEN:
  all bundles 0 failures (UI 312/53 skipped, Session 487, POC 7, Mac 19, MacOS 98, Core
  1974); signed build OK; `git diff --check` clean. LIVE PASS (2026-10-15, user + log): six
  Dock clicks each logged `focus click on system UI`, then `focus adopt source=activation ...
  changed=true scroll=...` (same workspace, strip scrolled) or `focus reveal id=1528:1
  workspace=2 source=activation` / `id=17415:4 workspace=1` (other workspace).

## Acceptance criteria
- Opening a new app or window after Gio starts tiles it without switching apps.
- Closing a window reflows immediately.
- Fixed-size windows appear in status as floating with reason `notResizable`.
- `swift test` green; signed Gio scheme builds.

## Applicable checks
- TDD: STRICT ON (source: user global CLAUDE.md "Strict TDD Mode: enabled"; supersedes
  the older "OFF" note in gio-niri-rewrite.md). Runner: `swift test`.
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- `git diff --check`.
- Review: RDD on (default). After each work-unit commit run
  `gentle-ai review assess --cwd <repo> --agent claude-code --base-ref <boundary> --committed-only --json`.
  First boundary: `31d17c0`.

## Delivery
Strategy `ask-on-risk`. Forecast ~600-900 authored lines across 5 tasks; one work-unit
commit per task on `feat/gio-niri-rewrite`. Push/PR not authorized.

## Routes
- WC-01..WC-05: delegated writer (2+ non-trivial files per task: GioMacOS + GioDesktop + tests).

## Progress
- 2026-09-29: document created after diagnosis. Next: WC-01.
- 2026-09-29: WC-01 done `6cfa1db` (route: delegated writer). Test-count note: 247 was declared `func test` count at 31d17c0, now 260 declared; runner executes 210 (pre-existing gap, not a regression). Next: WC-02.
- 2026-09-29: WC-02 done `d763b75` (route: delegated writer). Next: WC-03.
- 2026-09-29: WC-03 `e9c8066` + WC-04 `695ac17` done (route: one delegated writer, shared files). Next: WC-05.
- 2026-09-29: WC-05 done `b7fb956` (route: delegated writer). PHASE 1 CODE-COMPLETE; LIVE PENDING: user run of signed Gio scheme (open app after start, close window, minimize/restore, Electron app tiles). Delivery: ~1.2k authored lines over 5 commits exceeds ~400 budget; chain strategy deferred because push/PR are not authorized. Next: live validation, then phase 2 (perf).
- 2026-09-29: live run (user screenshots + ~/.config/gio/gio.log): tiling works but off-viewport windows stay stacked behind (`reconcile applied=2..3` per focus move). Added WC-06. Route: delegated writer.
- 2026-09-29: WC-06 done `3a30bbe`. Next: user live retest.
- 2026-09-29: live retest: parking works; clicks cause full re-layout (can't select), quitting leaves windows parked at 1pt, no animation (phase 2/4). Added WC-07, WC-08 (user-reported defects of built behavior). Route: one delegated writer, two commits.
- 2026-09-29: WC-08 `cb1781f` + WC-07 `4a6351b` done; 328 executed 0 failures (parent spot-check). Next: user live retest, then phase 2 perf.
- 2026-09-29: live retest: test 5 (quit restore) PASS; test 2 (click) intermittent FAIL with many windows. Added WC-09. Route: delegated writer.
- 2026-09-29: WC-09 done `9d25405`. Next: user live retest of click (look for `focus dropped` / `focus adopt ... parked`).
- 2026-09-29: WC-09 hypothesis (stale focus) REFUTED by logs; real cause reveal geometry. WC-10 done. Next: live retest click.
- 2026-09-29: LIVE PASS (user + log since last start: 53 focus adoptions, all `scroll=no scroll`, 0 `focus dropped`). PHASE 1 CLOSED. Next: phase 2 perf + animation in odd/tasks/motion.md.
- 2026-10-14: WC-11 native tabs done (`8effe33`, on `main` after SM-31 and FI-09..FI-11). LIVE PENDING: TESTING.md row 1b.
- 2026-10-14: WC-12 keyboard focus skips floating/minimized columns done (`19bddce`, route: delegated writer). LIVE PENDING.
- 2026-10-15: WC-13 Dock click reveals the app's workspace done (`f43daad`, branch
  `fix/dock-click-reveal`). LIVE PASS.
