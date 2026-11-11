# Fidelity: minimum sizes, overlap-free motion, failure visibility

## Objective
Windows with app-enforced minimum sizes tile without overlapping neighbours or retrying
forever, and animations of stacked/resized columns never show the old composition
overlapping the new one.

## Problem (live run 2026-09-29, screenshots + ~/.config/gio/gio.log)
- WhatsApp / Xcode / Activity Monitor stay wider than their column and overlap neighbours;
  the log shows `reflow ... failed=1` on every reflow and only "see firstFailure in tile
  report" — no window id, app or requested/actual frame is logged.
- Known macOS behaviour (earlier prototype, engram "gio-ax-size-clamp-policy"): apps clamp
  to an unpublished minimum size (e.g. requested 440 -> actual 500); AX exposes no minimum.
- Stacked columns (VS Code over OrbStack): during motion the previous composition overlaps
  for a moment. MotionPlayer lerps size every frame; Electron/OrbStack repaint resizes
  slowly (`anim done ... dropped=5 slowest=OrbStack 13ms`).

## Why
User (2026-09-29): "hay windows que hacen raro el tiling ... la composicion anterior se
sobrepone por un segundo". User approved fixing these before new Niri features.

## Scope (authorized)
FI-01..FI-03. New Niri features (dynamic workspaces, overview, trackpad, focus ring,
open/close animations, tabbed columns, mouse move) are not authorized yet.

## Constraints
Pure logic in GioCore with XCTest; only WindowReconciler writes; Gio never manages its own
pid; logs carry ids/app names, never titles. Conventional Commits, NO Co-Authored-By.
Push to origin feat/gio-niri-rewrite after verified batches; no PR. Quote trailing-space path.

## Tasks
- [x] FI-01 (`22e7c6d`) — Failure visibility: every reconcile failure logs id, app, kind, requested and
  actual frame (warn once per window+kind, debug afterwards).
- [x] FI-02 (`bd7447f`) — Learned minimum sizes: a size clamp (actual > requested, same position) records
  a per-window minimum; layout uses it (column width >= widest member's min width, stacked
  heights respect min heights); no retry storm; forgotten when the window is re-registered.
- [x] FI-03 (`75c59a9`) — Overlap-free motion: animate position only; apply size changes once (shrinking
  windows at the start, growing windows at the end) so neighbours never overlap mid-motion.

Evidence (route: one delegated writer): `reconcile failure id= app= kind= requested= actual=`
(warn once per window+kind); learning rule = >1pt larger with one edge anchored (both edges
moved = position clamp, not learned), minimums only grow, column width capped to viewport,
stacked heights pin mins; motionFrame = origin eased, shrink at first frame, grow on final pass.
Prepositions keep full frame (window fully below display; accepted by parent: cannot overlap).
Overlap geometry tests are regression guards only (pure model can't reproduce app repaint lag).
Bundles 20/7/19/23/647 all 0 failures (parent re-ran); signed build OK. LIVE PENDING.
Review: UNAVAILABLE.
- [x] FI-04 (`50d82a0`) — Hotkey tap resilience (live 2026-09-29): sessions 18:07Z/18:30Z/19:39Z had zero
  `hotkey` lines. `tapCallback` ignores `.tapDisabledByTimeout`/`.tapDisabledByUserInput`, so a
  macOS-disabled tap stays dead; tap always subscribes to mouseMoved (even with
  focus-follows-mouse off); main thread may block on session queue during slow reflows (495ms
  startup reflow). Fix: re-enable + watchdog, conditional mouseMoved, no main-thread queue.sync.
  DONE: re-enable on disable events + 2s watchdog, mouseMoved only with focus-follows-mouse,
  PublishedValue snapshot cache (no main-thread queue.sync except start/shutdown), MenuBar IPC
  off-main. Bundles 20/7/19/30/649 all 0 failures (parent re-ran); signed build OK. LIVE PENDING.
  Route: delegated writer. FI-02 LIVE PASS: `min size learned` WhatsApp w=970, Figma w=900.
- [x] FI-05 (`98ca22a`) — Render verification (live 2026-09-29): user saw an empty area where windows should
  be until pressing Alt+J; log at the time: final passes `already=10` (AX reported every window at
  target). Hypothesis: WindowServer/app did not reflect the AX move (Chromium/Electron after
  unparking). Fix: ~150ms after motion settles compare AX frames with CGWindowList bounds
  (public, no Screen Recording) for visible windows; log `render mismatch id= app= ax= ws=`;
  corrective nudge rewrite; log `render nudge ... fixed=<bool>`. Route: delegated writer.
  DONE: CGWindowList layer-0 pid+bounds snapshot, two-pass matching (exact then unique same-size,
  ambiguous skipped), mismatch vs AX frame, nudge = +1pt x then target (single shot), check 150ms
  after settle, re-check 100ms; cancelled by new motion / mouse down. Bundles 22/7/19/32/728 all
  0 failures (parent re-ran); signed build OK. LIVE PENDING (user: windows were missing).
- [x] FI-06 (`239b6d5`) — Move column + immediate keyboard focus (live 2026-09-29): Alt+Shift+H/L runs
  `moveWindow(.left/.right)`, which appends the window INTO the neighbour column (stacking; OrbStack
  then clamped 366 -> 452 high). Niri moves the whole column. Rapid keys: each retarget restarted
  the full 200ms (`anim done ... duration=1142ms`) and focus intent waited for the final pass, so
  typing went to the old window. Fix: Alt+Shift+H/L = move-column-left/right (swap, composition
  kept; stacking stays on Alt+[ / ]); apply keyboard focus immediately. Route: delegated writer
  (shared with NF-04).
  DONE: moveColumn swap on Alt+Shift+H/L (old move-window-left/right unbound, names kept),
  focusNow at motion start + reassert on final pass, ReflowCoalescer one reflow per tick.
  Bundles 22/7/19/32/747 all 0 failures. LIVE PENDING.
  Follow-up `ea629c8` (user: "cubre el caso de una vez"): final-pass reassert also on same-app
  drift (frontmost focused window != target) and once when unreadable; log `focus reassert id=
  reason=`. Bundles 22/7/19/32/771 all 0 failures (parent re-ran).
- [x] FI-08 (`c35f5b7`) — Live test round 2026-09-30: 24 `render nudge ... fixed=false` with
  `ws=missing` on visible windows (Chrome/Code/Finder/Ghostty/WhatsApp). Root cause: nudged set reset
  every settle (repeats, proven) + any unmatched window treated as missing (edge/peek windows,
  multi-window apps; partly inferred). Fix: evaluateRender (skip <50% on-screen, missing only if no
  same-pid entry covers >=30%, ambiguous/overlapsOther = unknown), one failed nudge per window then
  unverifiable, debug `render unmatched reason=`. RED compile -> GREEN; bundles 158(42 skipped)/7/19/
  39/1134 all 0 failures (parent re-ran); signed build OK. LIVE PENDING.
  Same live round PASSED: startup instant (3x), config edit+reload from app, native zoom 14/14
  `corrected verified=true`, quit restore 3x + guardian clean exit.
- [x] FI-09 (`a0f466e`) — Floating restore memory released after one settled attempt (user
  2026-10-14: a window kept appearing and disappearing after an installer prompt was dismissed; no
  logs). `planInactiveWorkspaces` returned a floating window's `HiddenWindowBook` frame in
  `plan.visible` until its physical frame matched within 1 pt; a restore that did not land (a dialog
  that re-centres itself; `foldSettle` drops the failed window's physical frame) never cleared, so
  every later reflow rewrote the dialog. Fix: `ReflowPlanner.restoreSettled(visible:deferred:)`,
  called from `foldSettle`, releases a remembered frame once a settled pass wrote exactly that frame
  and did not defer the window, landed or not; until then (a retarget mid-flight, an abandoned
  motion, a deferred window) the memory stays as before.
  RED: `swift build --build-tests` -> `value of type 'ReflowPlanner' has no member 'restoreSettled'`.
  GREEN: `swift test --filter ReflowPlannerTests` -> `Executed 25 tests, with 0 failures`.
  LIVE PENDING.
- [x] FI-10 (`248ef8a`) — Cap the app-vs-Gio frame fight (same report: a window flicking in and out
  after an installer prompt; no logs). A managed window whose app keeps restoring its own frame
  (re-centres, re-shows a parked window, refuses a position) was written back after every non-echo
  `.frameChanged` (`WindowEventRouter` -> `invalidateTrust` -> `scheduleReflow`), every ~0.3 s forever;
  a parked window on a hidden workspace flipped visible/parked forever. Decision: pure
  `SnapBackBook` (GioCore, injected time) counts non-echo frame changes that come at most 1.5 s after
  Gio's last write (`WriteEchoGate.lastWrite`, a dispatched write's latest landing) while no mouse
  button is down (a user drag never counts); 3 within 10 s make the window yield: new
  `FloatReason.appControlled`, mode floating, warn `window yields to app id= app= snapBacks=` once
  (no title), one pass for the neighbours. Gio never writes it again: floating leaves the scrolling
  and dwindle layouts, `ReflowPlanner` no longer parks it, restores its `HiddenWindowBook` frame or
  relocates it (MM-03), and its later frame changes only refresh the dim. It stays a workspace member
  (focus, overview, IPC). Toggle-floating tiles it again with a fresh count (the count resets at the
  yield); purge and re-registration forget the count (`forgetSnapBacks` from the host). Labels:
  overview "Floating (app keeps its frame)", badge "Floating · App-controlled", IPC
  `reason=appControlled`. A change later than 1.5 s after Gio's write never counts (limit).
  RED: `swift build --build-tests` -> `type 'FloatReason?' has no member 'appControlled'`, `value of
  type 'WindowEventRouter' has no member 'forgetSnapBacks'`, extra `lastWrite`/`isMouseDown` context
  arguments; with the planner change reverted the two new `ReflowPlannerTests` fail 3 assertions
  (yielded window parked, restored, relocated).
  GREEN: `swift test --filter "SnapBackBookTests|FloatingManagementTests|OverviewModelTests|
  WindowEventPolicyTests|OverviewPresentationTests|WindowEventRouterTests|DiscoveryServiceTests|
  ReflowPlannerTests|RichRuleArrivalTests|DeferredFollowTests|WindowOpenArrivalTests"` -> GioUITests
  `Executed 11 tests, with 0 failures`, GioSessionTests `Executed 93 tests, with 0 failures`,
  GioCoreTests `Executed 58 tests, with 0 failures`.
  LIVE PENDING.
- [x] FI-11 (`a0e265d`) — Re-check a late size clamp hidden by echo suppression (user 2026-10-14:
  tiled windows overlap; no logs). An app applying its minimum after Gio's immediate read-back passed
  the write check, was trusted at the requested frame, and its resize event landed inside the
  `WriteEchoGate` window and was dropped: no `frameMismatch`, no FI-02 learning, overlap until an
  unrelated event. Decision: a resized event of a known window dropped by suppression schedules ONE
  re-check per window (router, session scheduler) 50 ms after the echo window ends (moved events are
  not: every scroll raises them and a late clamp only follows a size write); a purged or
  yielded window is dropped, one Gio wrote again waits for the new echo window. It reads the frame and
  acts only on a size differing from Gio's last write (`lateFrameResized`, 2 pt; a position-only
  difference is a parking/menu-bar clamp). Deviation from the brief: a relayout alone would not learn
  (the next write passes its read-back again), so the re-check itself is the evidence:
  `MinimumSizeBook.learnLate` (FI-02 rule, requested = `WriteEchoGate.writtenFrame`) learns it, logs
  `min size learned ... late=true` and relayouts; a window a display-change pass placed last
  (`notePlaced` from `foldSettle`) teaches nothing. Any other size invalidates trust, schedules a light
  reflow and counts as an FI-10 snap-back (not during a drag, never learned then), so an unlearnable
  clamp yields after three instead of looping. Limits: one AX read ~0.4 s after the write per window
  whose size Gio wrote (pure moves cost nothing); a late same-size move is not re-checked.
  RED: `swift build --build-tests` -> `value of type 'WriteEchoGate' has no member 'writtenFrame'`
  (plus the missing `notePlaced`/`learnLate`/`learnLateClamp`); with the router's
  `scheduleLateCheck` call disabled `swift test --filter WindowEventRouterTests` -> `Executed 29
  tests, with 13 failures`. Integrator review (narrowed to `.resized`): the new
  `testAMoveHiddenByTheEchoWindowIsNotCheckedAgain` first failed 2 assertions
  (`Executed 30 tests, with 2 failures`).
  GREEN: `swift test --filter "MinimumSizeTests|WindowEventPolicyTests|SnapBackBookTests|
  WindowEventRouterTests|DiscoveryServiceTests|RichRuleArrivalTests|DeferredFollowTests|
  WindowOpenArrivalTests|ReflowPlannerTests"` -> GioSessionTests `Executed 100 tests, with 0
  failures`, GioCoreTests `Executed 52 tests, with 0 failures`.
  LIVE PENDING.

## Acceptance criteria
- WhatsApp/Xcode no longer overlap neighbours; `failed=` stays 0 after the first learn pass.
- Stacked-column moves show no transient overlap.
- All 5 test bundles green; signed build OK; docs updated.

## Applicable checks
- TDD: STRICT ON. Runner `swift test` (read all 5 "Executed" lines).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: UNAVAILABLE (gentle-ai trailing-space path defect; user chose continue).

## Routes
- FI-01..FI-03: one delegated writer.

## Progress
- 2026-09-29: document created. Next: FI-01..FI-03.
- 2026-09-29: FI-01..FI-03 done, pushed. Next: user live check.
- 2026-09-29: live: shortcuts dead all session (tap disabled, never re-enabled). FI-04 done, pushed.
- 2026-10-14: FI-09..FI-11 done (user report, no logs; worktree branch, cherry-picked onto `main` with
  SM-31 and WC-11). Integrated `swift test`: GioUITests 310 (53 skipped), GioSessionTests 475,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 95, GioCoreTests 1960, all 0 failures; signed
  `xcodebuild` BUILD SUCCEEDED; `git diff --check` clean. Not pushed. Next: live check (installer or
  re-centring dialog: `window yields to app`, `min size learned ... late=true`).
- 2026-11-04: FI-12 (`DONE`, `65a2ece`) — one snap-back per write. User screenshot: windows stacked over the tiles.
  `gio list-windows`: three Terminal windows `floating reason=appControlled`; the log had
  `window yields to app ... snapBacks=3` for all three at the same millisecond, 5 s after a relaunch
  (the Dock appeared and the strip was laid out again). One restore raises a burst (AX moved and
  resized, WS-03's window-server notices), and `SnapBackBook` counted every change after the same
  write, so one burst reached the cap. Now every change after the same write is one snap-back
  (`answered`); a real fight (the app restoring after each of three writes) still yields. RED:
  `SnapBackBookTests.testABurstAfterOneWriteCountsOnce` (2 failures); `testWindowsAreCountedApart`
  now uses a second write. Full `swift test`: Core 2282, Session 607, UI 389 (54 skipped), POC 7,
  Mac 19, macOS 120; signed build OK. Live: after the relaunch all Terminal windows are tiled, no
  `yields` line, the window server shows no window over the visible tiles. Not reproduced live with
  the burst itself (no debug log of the original event).
- 2026-11-04: FI-13 (`DONE`, `2510b7e`) — a yielded window left off screen. User screenshot: Activity
  Monitor frontmost, nothing of it on screen. Log: `window yields to app id=43492:11 ... snapBacks=3` at
  06:36:49 (the session before FI-12), then `overview move ... workspace=5` and `focus reveal id=43492:11
  workspace=5 source=activation`: it had yielded while its workspace was hidden, so it stayed at its
  parking sliver, and FI-10 never writes a yielded window again. The planner now brings a yielded window
  that its shown workspace leaves off every display fully on screen once (`rescuedFrame`, size kept,
  nearest place inside the display's visible frame; `float rescue` log line); one on screen anywhere,
  another display included, stays the app's. RED: `ReflowPlannerTests.testAWindowThatYieldedToItsApp...`
  (it asserted the stranding) and `testRescuedFrameKeepsTheSizeInsideTheVisibleArea` (compile failure).
  Still open: a Terminal window yielded again at 06:42:52 with the FI-12 build (three Terminal windows
  report the same frame, (771,69,741,872): likely one Terminal tab group; not reproduced).
- 2026-11-04: FI-14 (`DONE`, `7b5ecc5`) — windows lost during a screen lock. User (v0.1.7 release):
  windows left off screen that Gio did not manage. Log: SecurityAgent at 22:46:34, then at 22:52:10 a
  rescan while `loginwindow` (pid 412) owned the screen logged `discovery exclude ... ignore(notAWindow)`
  for nine apps: every window answered no role. Their apps still counted as fully read
  (`completePIDs`), so `vanishedWindowIDs` purged Music, Figma, OrbStack and Bitwarden, parked at
  their slivers; no event re-adopted them after the unlock (window server: Bitwarden x=-743, Music
  x=-979, Figma x=-899, OrbStack x=-743, all unmanaged). Rule 10 broken: an unreadable answer was taken
  as proof. Now a window whose role does not answer (and that is not destroyed) is skipped
  (`discoverySkips`): its app is not fully read and nothing of it is purged. RED:
  `WindowFactsDecodingTests.testAnUnreadableRoleIsSkippedNotIgnored` (compile failure). Also seen: the
  dev session quit at 07:18 during a lock (`readbackFailed -25204`) restored 0 windows, so they started
  the release parked; the first release launch had no Accessibility yet (expected: nothing managed
  until the grant relaunch). NOT verified live with a real lock.
- 2026-11-05: FI-15 (`DONE`, `546854e`) — every window purged when the Mac locked. Live debug log
  (`~/.config/gio/gio.log`, ~3600-3660), the Mac going to sleep/lock at 02:14:20, in one burst:
  ```
  [DEBUG] reconcile applied=0 parked=0 already=8 skippedReads=8 vanished=1 failed=0
  [INFO] window register retry pid=412 attempt=1 reason=frameUnreadable   (412 = loginwindow)
  [INFO] discovery exclude pid=33460 app=System Settings ignore(notAWindow)
  [DEBUG] window vanished scan pids=1 purged=1 registered=0
  [DEBUG] reconcile ... vanished=2 ...
  [INFO] discovery exclude pid=20267 app=Music ignore(notAWindow)
  ... (repeats until every app: Music, T3 Code, Figma, OrbStack, Tern, Slack, Finder, Zen purged)
  ```
  Root cause: while the screen locks, the reconciler's AX reads find the elements invalid (SM-31
  `vanished`), each asks for a proof scan of its pid, and the app's window list then holds only
  non-window elements whose role does answer (`notAWindow`, so FI-14's unreadable-role skip does not
  apply): the pid counts as fully read and `vanishedWindowIDs` purges its windows. After the wake
  the window server still listed them, but Gio managed only the 3 that raised a new "window created"
  event. Rule 10 broken again: the AX list's silence was taken as proof. Fix: absence must be
  confirmed by the window server. Before the scan purge (`vanishedWindowIDs`, used by full scans,
  launch scans and SM-31 proof scans alike), `confirmedVanished` (Core) keeps every candidate whose
  recorded window number (WS-04, `WindowNumberBook`) the window server still lists (one
  `CGWindowListCopyWindowInfo(.optionAll)` per purge batch, `windowServerListedNumbers`, asked only
  when a number could keep a window): `window kept id=P:E reason=window-server-alive`. A window with no
  recorded number is purged as before; a destroyed notice (WS-02, now `DiscoveryService.noteDestroyed`)
  is proof on its own and rescans even a vanish already scanned. Unchanged proof paths: the AX
  destroyed event (`WindowEventRouter` `.remove`), a terminated app (`appTerminated`) and a dead pid
  (`reapDeadPids`). A kept window is re-read by the next scan: a system wake
  (`NSWorkspace.didWakeNotification`) and a screen unlock (`com.apple.screenIsUnlocked`) now ask for one
  full, debounced resync (`session rescan reason=<wake|unlock>`); if the app hands it a new AX element,
  its registration takes over the number and the old id, numberless, is purged by the same scan. Risk
  [INFERENCE]: an app that hides a closed window instead of destroying it keeps its tile until the AX
  destroyed event or the app's quit (the AX event is the normal close path; the scan purge is a
  fallback). RED: compile failure (`VanishConfirmationTests`: `confirmedVanished`, `VanishConfirmation`,
  `vanishNeedsWindowServer` missing; `VanishedWindowScanTests` FI-15 cases: context `windowNumber`,
  `liveWindowNumbers`, `noteDestroyed` missing; `WindowServerSnapshotTests.testListedNumbersKeepEvery...`).
  GREEN: Core 2298, Session 621, UI 391 (54 skipped), POC 7, Mac 19, macOS 127; `git diff --check`
  clean; signed build not run (a dev Gio was running). NOT verified live with a real lock or sleep.
- 2026-11-06: FI-16 (`DONE`, `fdd83d3`) — a window on screen never managed, across a launch and a
  sleep/unlock. Live release v0.1.11 (`~/.config/gio/gio.log`, ~5560-5600):
  ```
  [2026-11-06T00:47:26.737Z] [INFO] window server scan pid=71363 reason=unregistered   (LoopOps ADE, launched 00:47:23)
  ... no "window open" for pid 71363 ever ...
  [2026-11-06T02:59:47.141Z] [INFO] session rescan reason=unlock
  [2026-11-06T02:59:48.539Z] [INFO] discovery exclude pid=640 app=Finder ignore(notAWindow)
  [2026-11-06T02:59:49.843Z] SecurityAgent windows (still unlocking)
  ```
  Afterwards the window server listed the LoopOps window (number 8530, layer 0, on screen, AXWindow/
  AXStandardWindow 1440x900) while `gio list-windows` did not; `gio restart` adopted it at once. Cause
  [INFERENCE, from the log]: both scans ran while the app's Accessibility was not ready (just launched;
  then mid-unlock), so its window was skipped (FI-14 `discoverySkips`, debug only) or not listed, and
  nothing asked again: the WS-02 rescue scan runs once, the FI-15 unlock rescan once, right when the
  screen unlocks. Fix: (1) retries: a scan that skipped windows of a pid
  (`SystemWindowDiscoveryResult.skippedPIDs`, `DiscoveryService.Context.scanFinished`) or a rescue scan
  that left the window unregistered starts a per-pid series, scans after 0.5, 1.5, 4, 10 s
  (`StrandedWindowRetry.delays`, `StrandedWindowRetryBook`, Core), ending once the app is read fully with
  nothing stranded, the window server drops the window or the app dies (`window retry scan pid=N
  attempt=N reason=skipped|unregistered`, `... gave up attempts=4 ...`); (2) after a wake or unlock the
  full rescan runs again at 2 s and 6 s (`wakeSettleDelays`, `session rescan reason=unlock settle=2s`;
  a later wake replaces pending settles); (3) safety net: after every full scan and at most every 30 s
  (`auditInterval`), `strandedServerWindows` (Core) diffs the on-screen layer-0 windows of regular apps
  (never Gio's own) against the registered numbers and starts the same series (`window server stranded
  pid=N windows=N`). A series that gave up remembers its numbers (`rejected`) until the window server
  drops them or the Mac wakes, and a skip series that gave up waits for a full read of its pid, so a
  window admission refuses is not rescanned forever. Component: `StrandedWindowRescue` (GioSession,
  `SessionScheduler`); `SessionHost` only wires it (watcher `scanApp`, discovery `scanFinished`,
  `watchWake`, `start`). RED: compile failure (`StrandedWindowRetryTests`: `StrandedWindowRetry`,
  `StrandedWindowRetryBook`, `WindowRetryStep`, `strandedServerWindows` missing;
  `StrandedWindowRescueTests`: `StrandedWindowRescue`, `scanFinished`, `skippedPIDs` missing;
  `WindowServerWatcherTests.testRegisteredNumbersFollowRegistrationAndForget`: `registeredNumbers`
  missing). GREEN: Core 2349, Session 643, UI 391 (54 skipped), POC 7, Mac 19, macOS 131, 0 failures;
  signed Debug build succeeded (app unregistered and deleted after); `git diff --check` clean. NOT
  verified live (needs an app whose Accessibility answers late at launch, and a real lock/unlock).
- 2026-11-06: FI-17 (`DONE`, `9f57802`) — Zen stuck at full width, `Alt+F` did nothing. Live release
  v0.1.11: Zen's window stayed 1496 pt wide (the whole strip); maximize-column toggled its stored width
  (1.0x and back) but the frame never shrank. `~/Library/Caches/dev.gio.windowmanager/
  app-minimum-sizes.json` held `bundle:app.zen-browser.zen: [1496, 2, 495, 2]` (width confirmed twice,
  PA-24) and `bundle:so.stencil.tern: [1496, 1, ...]`. Log (`~/.config/gio/gio.log`, ~3905-3926):
  ```
  20:41:24.194Z space foreign; pausing layout        (the user was in a native fullscreen Space)
  20:41:52.460Z space managed; reflow
  20:41:52.500Z window float id=1021:100 app=Zen reason=notResizable
  20:41:52.524Z [WARN] reconcile failure id=1021:101 app=Zen kind=frameMismatch requested=(760,8,744,934) actual=(760,8,1496,934)
  20:41:52.532Z min size learned id=1021:101 app=Zen w=1496 h=0
  20:41:52.532Z window open id=1021:101 app=Zen ... (registered 2 ms earlier)
  ```
  Cause: a false learned minimum. The window had just come back from the fullscreen Space and just
  registered, still at its old full width; the app had not applied the resize yet, and
  `learnedMinimum` (FI-02/BUG-2/FX-05/NC-15 rules) read the unchanged size as a clamp. Clearing the two
  entries and restarting fixed it live (Zen 1496 → 744 on `Alt+F`). Fix (`MinimumSizeBook`,
  `AppMinimumSizes`, Core): (1) `ReconcileFailure.before`, the frame the lane read before the write;
  `learnedMinimum(requested:actual:before:)` gives no evidence on an axis whose landed extent equals the
  pre-write one. Alone that would never learn a window already sitting at its minimum (or one whose
  first clamp was held back by (2): the next write finds it at the clamp), so the book keeps such a
  clamp `pending` and counts it when the next write shows the same one (the app refused twice; a
  landed write clears it); the result's `recheckAt` makes the host run one light reflow (at once for a
  first kept size); (2) no learning within `MinimumSizeBook.settleDuration` (1.5 s) of a window's
  registration (`noteRegistered`, `resetWindowState`) or of the managed Space coming back
  (`noteSpaceReturned`, new `SpaceCoordinator.Context.resumed`, run before the rescan), late re-check
  included; `recheckAt` = the settle's end; (3) an axis at least as large as the strip holding the
  requested frame (`tilingStrip(holding:in:)`, each display's usable frame less `padding`) is never
  learned or confirmed (`min size ignored id=... w=... reason=full-width|full-height|full-size`, info;
  `settling`/`unchanged` at debug); (4) after the first display sync (`initialSync`),
  `AppMinimumSizes.purgeImplausible(strips:)` drops PA-24 entries with an axis at least the largest
  strip's and rewrites the file (`min size purged app=<key> w= h= reason=full-strip`). Trade-off
  [INFERENCE]: a real minimum on a window that just opened is learned about 1.5-2 s later than before
  (one more overlap-pass of its neighbour); a window already at its minimum is learned on its second
  refused write instead of the first. RED: compile failure (`MinimumSizeTests`: `learnedMinimum(before:)`,
  `MinimumLearning`, `IgnoredMinimum`, `noteRegistered`, `noteSpaceReturned`, `settleDuration`,
  `learn(from:placement:now:strips:)`, `ReconcileFailure.before` missing; `AppMinimumSizesTests`:
  `purgeImplausible` missing; `SpaceCoordinatorTests`: context `resumed` missing). GREEN: Core 2354,
  Session 643, UI 391 (54 skipped), POC 7, Mac 19, macOS 131, 0 failures; signed Debug build succeeded
  (app unregistered and deleted after); `git diff --check` clean. NOT verified live (needs Zen in a
  native fullscreen Space and back, and a launch with a stale full-width entry in the store).
- 2026-11-10: FI-18 (`DONE`, commit below) — windows animating in the Fast preset after a while. User: "después
  de una suspensión o un largo periodo de uso, aunque tenga el modo fast, algunas ventanas tienen como la
  animación entre ventanas ... cuando reinicio todo vuelve normal". Log: no animation outside gesture
  settles (`anim done` only after `gesture scroll end`), but after each wake Zen started a run of
  `render mismatch ... app=Zen ax=(8,8,...) ws=(161,8,...)` and a `render nudge ... app=Zen tier=position`
  on almost every move (44 an hour on 2026-11-10 04:00, 46 at 15:00) that stopped only when Gio
  restarted. Probe: Zen had `AXEnhancedUserInterface` on; with it on, a 1511 → 8 position write slides
  over ~120 ms (515, 233, 106, 66, 19, 9, 8 sampled every 20 ms), with it off it lands at once. Zen
  applies `AXEnhancedUserInterface` writes but answers them with `kAXErrorNotImplemented` (-25208), so
  PF-K's guard took every restore as refused (`enhanced ui restore failed`), marked Zen owed, and owed
  apps skipped the switch-off before the next writes: Gio wrote Zen with the attribute on for the rest
  of the session. Fix (`EnhancedUIGuard`): a restore whose write errs is read back, and a value read as
  on is a done restore; an owed app is switched off before its next batch anyway. RED:
  `EnhancedUserInterfaceTests.testARestoreTheAppAppliedButReportedAsFailedIsNotOwed` and
  `testAnOwedAppIsSwitchedOffBeforeTheNextBatch` (4 failures; the owed test now also expects the
  read-back and the switch-off). GREEN: Core 2358, Session 643, UI 391 (54 skipped), POC 7, Mac 19,
  macOS 132; signed build OK; `git diff --check` clean. NOT verified live (needs a release and a few
  wakes with Zen).
