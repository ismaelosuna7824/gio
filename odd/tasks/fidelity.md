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
- [x] FI-09 (commit pending) — Floating restore memory released after one settled attempt (user
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
- [x] FI-10 (commit pending) — Cap the app-vs-Gio frame fight (same report: a window flicking in and out
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
- [x] FI-11 (commit pending) — Re-check a late size clamp hidden by echo suppression (user 2026-10-14:
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
