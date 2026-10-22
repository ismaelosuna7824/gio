# Performance audit: idle ~0%, cheaper frames, adaptive size animation

## Objective
Cut Gio's CPU/energy (Xcode showed "Energy Impact: Very High") to near zero at idle and much
lower during motion, and make maximize/resize animations grow smoothly where the app supports it.

## Problem (read-only audit 2026-09-29, ranked; evidence file:line in the audit summary)
1. `GioLog.record` reopens the log file per line (~6 syscalls + new ISO8601DateFormatter), no
   level gate, interpolation always built; log never rotated (1.2 MB, 7.9k DEBUG lines).
2. Motion timer fixed at 120 Hz regardless of display refresh.
3. `NSRunningApplication(...).localizedName` per window write per frame (timing only).
4. Per-frame closure/worker/DispatchGroup per pid; AX call counter lock per AX call; unbounded
   timing array.
5. Final pass reads AX frames of every window incl. parked ones Gio placed itself.
6. Render verification: `CGWindowListCopyWindowInfo(.optionAll)` + AX reads of all targets per settle.
7. Sub-point/no-op writes (tolerance 0.5 vs 1 mismatch); spring tail ticks at 120 Hz.
8. Focus ring published + dictionary merges every motion tick.
9. Idle polling: MenuBar IPC status every 3s (socket per poll); tap watchdog every 2s.
10. `id(matching:)` linear CFEqual scan per AX moved/resized event, before the echo gate.
11. Full-resync path (all-app AX enumeration) still reachable on activation when tap refused.
12. UI tickers: LogsView re-reads 256 KB + renders 1000 rows every 1s; other views 2-3s.
13. Debug log writes on hotkey/focus hot paths (covered by 1).
14. Inactive-workspace parking re-planned every reflow; hidden windows iterated in reconcile.
Animation: FI-03 `motionFrame` defers every grow to the final pass, so maximize looks cut
(neighbours retreat, then the window jumps). Per-app timing exists but never feeds the planner.

## Why
User (2026-09-29): focus on code before new features; better performance and animation
control; maximize should not look cut; "consumir mucho menos".

## Scope (authorized)
PA-01..PA-06 below. No new user-facing features beyond config for log level / adaptive grow.

## Constraints
Pure logic in GioCore with XCTest; only WindowReconciler writes; Gio never manages its own pid;
main thread never waits on the session queue. Conventional Commits, NO Co-Authored-By. Push to
origin feat/gio-niri-rewrite after verified batches; no PR. Quote trailing-space path.

## Tasks
- [x] PA-01 (`8255385`) — Logging: one persistent handle, static formatter, `@autoclosure` + min level
  (default info), background batched writes, rotation ~1 MB, drop routine debug noise. (#1, #13)
- [x] PA-02 (`22f7024`) — Idle ~0%: MenuBar refresh on menuWillOpen/push instead of 3s IPC poll; watchdog
  relaxed (30s, large leeway); UI tickers only while the main window is visible; LogsView tails
  from last offset, no textSelection on 1000 rows. (#9, #12)
- [x] PA-03 (`5f291e5`) — Frame pacing: timer interval from the display's maximumFramesPerSecond; whole-point
  rounding + unified tolerance 1; spring ends under 1pt residual; no per-frame appName lookup;
  timings aggregated in place; AX call counting debug-only. (#2, #3, #4, #7)
- [x] PA-04 (`2f655e0`) — Lean settle: trust `physicalFrames` for windows Gio placed (skip AX reads for parked /
  unchanged), render verification on-screen-only snapshot for visible targets, ring/echo/physical
  updates only for changed windows, cached inactive-workspace plan, hash-indexed handle lookup +
  echo check before resolution. (#5, #6, #8, #10, #14)
- [x] PA-05 (`4d65bc3`) — Per-pid persistent write lanes (no per-frame closure/worker allocation). (#4)
- [x] PA-06 (`a1e725f`) — Adaptive size animation: per-app EWMA of write cost/drops/clamps; fast apps grow
  during flight (maximize grows while neighbours retreat, no overlap along the path); slow apps keep
  the FI-03 final-pass grow.

Evidence PA-01/02 (route: one delegated writer): autoclosure + min level (default info),
persistent batched sink (32 lines / 100ms, warn+ immediate), rotation 1MB -> gio.log.1,
`[logging] level`; menu bar push (`publishBarState`) instead of 3s IPC poll, watchdog 30s,
UI tickers only while window + section visible, incremental LogTail (500 rows). TDD note:
PA-01 sink written before its tests (mutation-checked level gate instead of pre-impl RED) —
deviation recorded. Bundles 25/7/19/32/795 all 0 failures (parent re-ran); signed build OK.
Remaining periodic: 30s watchdog, visible-only UI refresh, motion timer during animations.
LIVE PENDING.

Evidence PA-03/05 (route: one delegated writer, pre-implementation RED on both): refresh rate
from NSScreen.maximumFramesPerSecond (main, published), interval fixed per motion (30-120Hz),
whole-point origins, shared 1pt tolerance, spring end <0.5pt; per-pid MotionWriteStats +
AppNameCache (no per-write name lookup); AX call counting debug-only; persistent serial lane
per pid with latest-frame slot (overwrite = drop), forgetApp on terminate, waitForMotionIdle
counter. Bundles 25/7/19/32/822 all 0 failures (parent re-ran; writer ran twice + 15x motion).
Not run under TSAN. LIVE PENDING.

Evidence PA-04 (route: delegated writer, pre-impl RED compile): TrustedFrames (skip AX read when
desired == trusted; invalidated by non-echo move/resize, minimize/restore/purge/re-register,
failure, motion/preposition start, display change), render check only written visible targets,
onScreenOnly snapshot, reuses settle frames (0 AX reads), in-place per-tick bookkeeping,
FocusRingPublishGate (<1pt dropped), HandleIndex by CFHash, early motion-echo drop per pid,
PlanMemo. Bundles 25/7/19/32/870 all 0 failures (writer 2 runs + parent re-run); signed build OK.
Risks: windows moved without AX events stay trusted until next event/motion; motion-echo drop is
per pid. LIVE PENDING.

Evidence PA-06 (route: delegated writer, pre-impl RED compile): ResizeCapability per app name
(EWMA 0.4, cost <=4ms, drops <=10%, >=2 usable motions, clamp blocks 5 motions), SizePlanner
overlap check 5-95% vs neighbours' motionFrames (1pt tolerance), delayed grow from first clear
step, spring progress on dominant origin axis, `[animations] resize = adaptive|always|never`,
`anim done ... sizeAnimated=N`. Bundles 25/7/19/32/890 all 0 failures (parent re-ran); signed
build OK. Gaps: cost learned from position-only writes. LIVE PENDING. ALL PA TASKS CODE-COMPLETE.
- [x] PA-07 (`2b1fc67`) — Live (ax renderer): Alt+H/J now fluid, maximize still looks cut (grow
  at final pass). Focused growing window gets `.atStart` size schedule: one size write in the first
  frame on the already-raised window, origin animates; overlap with retreating neighbours accepted
  (frontmost). `[animations] focused-grow = start|end` (default start); applies to fullscreen via
  focus intent and to maximize/presets via new `growsFocusedWindow` sizing target. `anim done ...
  grewAtStart=N`. Bundles 25/7/19/33/1000 all 0 failures (parent re-ran); signed build OK. LIVE
  PENDING. Gap: same-app z-order during flight.
- [x] PA-08 (`f0d03e3`) — Diagnostic: user reports first maximize of a window still "waits then
  expands", second is fluid, although `grewAtStart=1` and size writes are fast. Hypothesis: app
  repaints late the first time it reaches a new size. Probe: per grown window, CGWindowList
  (.optionIncludingWindow) polled per frame until bounds match (<=1.5s); log `resize latency id=
  app= requestedSize= wsMs= first=`. Bundles 25/7/19/33/1008 all 0 failures (parent re-ran).
  LIVE PENDING: user measurement.
- [x] PA-09 (`e2aabcf`, `a778d80`) — Live probe confirmed first-time-size repaint 330-750ms
  (Code/Slack/Pen/Xcode/WhatsApp/Figma), later 9-49ms. Native double-click zoom is smooth because
  the app animates in-process. Alt+F now performs the window's native zoom (`AXZoomWindow` on the
  zoom button — `AXPress` there enters full screen, verified read-only on live windows), neighbours
  spring as usual, settle via CGWindowList stable 2 polls (<=1.2s); accept if every edge within
  32pt (no correcting write), correct once within 96pt, else fallback; restore presses zoom again
  when the maximize was native; `[animations] native-zoom` (default true); log `native zoom ...
  result=`. Probe skips non-resizable/unchanged windows. Bundles 25/7/19/39/1054 all 0 failures
  (parent re-ran); signed build OK. LIVE PENDING.
- [x] PA-10 (`a53234d`) — Live: every Alt+F logged `fallback(pressFailed) ms=0` yet the window
  zoomed edge-to-edge without gaps and the ring was inconsistent. Cause (code-confirmed): the
  0.25s write-lane stall timeout abandoned the blocking `AXZoomWindow` press -> Gio wrote the
  fallback, then the app's zoom finished and overwrote it. Fix: lane abandonment / -25204 =
  pending (settle decides, 1.5s timeout), 1.0s messaging timeout on the zoom button, definitive
  AX errors fall back with the code logged; accept only <=2pt, else one correcting write to the
  gapped target (`exact|corrected|fallback(...)`); `[focus-ring] hide-when-maximized` (default
  true). TDD deviation: tests written first but RED not observed. Bundles 25/7/19/39/1064 all 0
  failures (parent re-ran); signed build OK. LIVE PENDING.
- [x] PA-11 (`6c5364e`) — Live: WhatsApp/Figma `fallback(mismatch) ms=34-41` ended edge-to-edge (multi-
  stage app zoom judged during a pause, then the app overwrote Gio's write); Pen correction timed
  out (`app busy`). Settle now needs 150ms quiet + >=120ms since press; NativeZoomVerifier checks
  ~250ms after any corrective write and reasserts once (`native zoom reassert reason=`); log adds
  `settleMs=` and `verified=`. RED observed (compile). Bundles 25/7/19/39/1078 all 0 failures
  (parent re-ran); signed build OK. LIVE PENDING.

### Second pass (2026-10-21): renders, startup/bundle, requests, AX N+1, assets/scripts
User (2026-10-21): web-style checklist (renders, lazy loading/bundle, requests+caching, slow
queries/N+1, images/fonts/scripts) mapped to Gio: SwiftUI publishes, launch work and the Release
binary, IPC/tccd/WindowServer requests, AX attribute round trips, icons and build/CI scripts.
Route: 5 read-only audits, then 5 delegated writers (file-disjoint, no builds mid-flight), parent
integrated, built and tested once. TDD deviation: writers wrote tests first but could not run
them (no RED observed) except AppNameCache (RED observed by parent: 3 failures, then GREEN).
- [x] PA-12/13/14 (`d0f23a6`) — Renders: `GioConfig`/`SessionSnapshot` Equatable; DesktopModel,
  LoginItemModel, SettingsDraft.adopt skip unchanged values (1-3 s polls re-rendered the whole
  window). `AppIconView` via pid-keyed `RunningAppIconCache` (128 px raster, misses cached,
  dropped on launch/quit); launcher window-row misses cached. Launcher rescan stat-first: parses
  only new/changed Info.plists (was ~91 per system app launch).
- [x] PA-15/16 (`3c42881`) — Session: bar state built from the session (no JSON encode/decode per
  reflow), `hasFocusedWindow` Bool; facts read cached Screen Recording permission, tccd only
  while missing; `primaryHeight` from DisplayParameters; resize probe (PA-08) only at debug
  level; one host AppNameCache that keeps only resolved names; sizeSchedules once per pid;
  launcher icon scan 2 s after session start; updater not forced before the session,
  eligibility on first use.
- [x] PA-17 (`9418311`) — IPC: `gio doctor` over IPC deadlocked (self-connect to the
  single-threaded server from inside `queue.sync`); in-session doctor no longer connects.
  Socket timeouts (client 60 s, server 5 s request I/O), SO_NOSIGPIPE, `IPCError.timedOut`.
  Launcher workspace/`>` commands off main.
- [x] PA-18 (`4ddc5f4`) — AX N+1: discovery one `AXUIElementCopyMultipleAttributeValues` per
  window + lazy settable probes (skipped for known windows): ~8-9 messages -> 1 known / 3 new.
  Verify read-back one batched read. Drag: one AX frame read per window per drag (tabs exempt).
  No double observer subscription. Dead `.resync` removed.
- [x] PA-19/20 (`c374cd7`) — Build: Release dead-code stripping + strip + dSYM artifact. Same
  source, measured: binary 13,312,832 -> 5,833,184 B, app 16.7 -> 9.4 MB, exported symbols
  49,459 -> 1; dSYM UUID matches, `atos` symbolicates. Dev stamp: first phase writing the
  processed Info.plist, real inputs/outputs, write-on-change: second Debug build ran no stamp,
  no plist processing, no CodeSign (`0.1.0+dev` kept). CI cache keyed by Xcode version + sha
  with restore prefixes; release test job restore-only.

Evidence: bundles UI 329 (53 skipped) / Session 546 / POC 7 / Mac 19 / MacOS 102 / Core 2098,
all 0 failures (baseline 313/537/7/19/91/2084). Signed Debug build OK twice; Release build OK
and `codesign --verify --deep --strict` OK. Script tests: stamp 8/8, release-version all pass;
workflows load as YAML. NOT verified: CI cache behavior (needs two runs), live `gio doctor`,
live drag/discovery/launcher timing, Screen Recording grant pickup, Instruments render counts.
Not done (left for a decision): persistent launcher icon cache on disk; overview thumbnails from
the snapshot cache; `Assets.car` 3.4 MB from the 1024 px raster icon layer (needs an Icon
Composer vector/recompressed export); config parsed three times per Settings apply;
`AXIsProcessTrusted` per frame write (unmeasured); `registerNew` O(N^2) pid scans (<1 ms at
N=100); overview rows re-render on hover; LogsView `@State` ticks; ~215 ms main-thread wait on
`initialSync` at launch.
- [x] PA-22 (`63e4181`) — User chose (2026-10-21) the two largest leftovers. Launcher icons on
  disk: `LauncherIconStore` (`~/Library/Caches/<bundle id>/launcher-icons.plist`, PNG per bundle
  path + Info.plist date + icon side, atomic rewrite only when a scan drew or dropped an icon);
  the first scan of a launch starts from it. RED: compile (`cannot find 'LauncherIconStore'`);
  GREEN `LauncherIconStoreTests` 3 (round trip at point size, other side/garbage = empty, second
  catalog draws only the changed bundle). Throwaway probe (real /Applications, temp store, 92
  apps): cold 375 ms, from the store 27 ms; store 523 KB. Tests never touch the real Caches
  (store and draw injected; app passes `.userCache()`).
- [x] PA-21 (`a6e3ccd`) — Launch without the main-thread wait: `start(onReady:)` returns after
  lock/config/IPC; `initialSync`, `events.rebuild`, first publication run with `queue.async`
  (`session ready`), then tap, touch source and `onReady` (window refresh, launcher scan in 2 s)
  on main; guards: `isShuttingDown` (queue), `mainShutDown` (main, was `multitouchShutDown`).
  No unit test (GioDesktop has none; ordering/wiring only). Bundles UI 333 (53 skipped) /
  Session 548 / POC 7 / Mac 19 / MacOS 102 / Core 2100, all 0 failures; signed Debug build OK;
  `git diff --check` clean. Hashes are the merged ones (PR #18, rebased).
  Live (user's Xcode Debug runs, `gio.log`): window `session started` -> `launch ... window=`
  1.33 s before (16:20Z) vs 0.98 s / 0.67 s after (16:36Z, 18:11Z); launcher `appsReady ms=561
  drawn=92` before vs `ms=84 drawn=0` (startup) and `ms=57 drawn=0` (refresh) after. Hotkeys
  started later: ~0.54 s before vs `session ready` at 1.71 s / 1.50 s, because both new runs had
  a slower first pass (NoteX and WhatsApp timing out, `reconcile failure kind=timeout`).
  Read-only A/B of `discoverSystemWindows()` on the live desktop (7 runs x 2 rounds): before
  PA-18 (`50fe4e0`) cold 251/298 ms, median 11/16 ms; after (`origin/dev`) cold 285/267 ms,
  median 9/9 ms: discovery did not get slower, the cold first pass is the apps.
- [x] PA-23 (`cc20286`) — Hotkey tap at the end of `start()` (after both startup steps are queued) instead
  of at `session ready`: a shortcut pressed during startup is taken (never typed into the
  frontmost app) and its action, which hops to the session queue (`handleCombo`), runs right
  after the first layout and the observer rebuild. Touch source and `onReady` unchanged. Wiring
  only, no unit test (GioDesktop); `swift build` and signed Debug build OK. LIVE PENDING: press
  Alt+L right after launching Gio: no character in the frontmost app, the focus moves once
  `session ready` logs.
- [x] PA-24 — Live log audit (2026-10-21, 16:39-20:23 UTC, 5 launches, 1074 hotkeys, 393
  snapshot flights, Debug build): `snapshot paint check` 145 runs / 205 windows, 0 blank, 0
  partial; no watchdog, no prime failure, 3 aborts all `mouse-down`; tap never re-enabled;
  2.9% frames dropped (821 of 27,230), 33 flights with 3+ hitches; guardian restore live once
  (16:41:23, `applied=9 failed=0`, no crash report: a forced stop). One overlap source: 22
  `frameMismatch` right after each launch (WhatsApp 970 pt, Figma and NoteX 900 asked 888): the
  learned minimums lived in memory only, so every launch overlapped a neighbour once until the
  relayout. Fix: `AppMinimumSizes` per app (bundle id, else name) in
  `~/Library/Caches/<bundle id>/app-minimum-sizes.json` (`AppMinimumSizeStore`), loaded before
  `initialSync`, saved only when an app's minimum grows (`logLearnedMinimum`), and the layout
  uses this session's minimum else the app's (`effectiveMinimumSizes`; no registry pass while
  the file is empty, then one pass over the windows per engine build, like `ruleWidthLimits`).
  RED compile (`cannot find 'AppMinimumSizes'`), GREEN `AppMinimumSizesTests` 4. Bundles UI 341
  (53 skipped) / Session 550 / POC 7 / Mac 19 / MacOS 102 / Core 2114, all 0 failures; signed
  Debug build OK. Tradeoff: a window of the app that could be narrower is never laid out below
  the app's minimum (delete the file to reset). LIVE PENDING: after one launch that learns
  WhatsApp/Figma/NoteX, the next launch logs no `frameMismatch` or `min size learned` for them.
- [x] BUG-1 — Stacked columns were drawn upside down (live 2026-10-21: Slack consumed into
  OrbStack's column showed on top, and focus-up from it went to OrbStack below). The model
  reads a column top to bottom (focus-up = previous, consume "joins at its bottom" = append),
  but `ScrollableLayoutEngine` put window 0 at `viewport.minY` (Cocoa: the bottom). Fix: stack
  from `viewport.maxY - padding` down; `makeWorkspaceStrip` measures `top` from the top for
  both layouts. Three engine tests had pinned the inverted y (taught to agree); updated. RED:
  `testVerticalStackSharesHeightEquallyFromTheTop` (y 8 vs 536).
- [x] BUG-2 — PA-24 persisted a transient clamp: Figma's first dwindle write read back 1784 pt
  (its old maximized width) and was saved as Figma's minimum for every launch. App minimums
  are now candidates until learned again with the same value (another session or another
  window; `AppMinimumSizes.Entry.seen`, `confirmations = 2`); only confirmed ones lay windows
  out; a different value replaces the candidate. Store format v2 (`{"version":2,"apps":
  {key:[w,h,seen]}}`); the first format (unconfirmed single clamps) reads as empty, so the
  live file's 1784 is dropped. RED: `AppMinimumSizesTests` (5 failures).
- [x] BUG-3 — Alt+Shift+T to dwindle with nine windows: tiles of 104x132 pt, every app clamped,
  late clamps counted as snap-backs, passes rewrote the windows every ~1.5 s, Figma yielded to
  `appControlled` (floating, so Alt+F ignored it). `DwindleLayoutEngine(minimumSizes:)`: a
  split gives each side its subtree minimum along its axis when both fit, else the two needs'
  proportion; unpinned orientations from the nominal rects. `MinimumSizeBook.explains`: a late
  clamp to a known minimum is kept (no snap-back, no relayout). RED: `DwindleLayoutEngineTests`
  (compile, then 2 failures on the nested case), `testALateClampToAKnownMinimumIsExplained`.
  Evidence (BUG-1..3 + WO-02/03): bundles UI 354 (53 skipped) / Session 550 / POC 7 / Mac 19 /
  MacOS 107 / Core 2149, all 0 failures; signed Debug build OK. LIVE PENDING: stacked column
  order and Alt+J/K, Alt+Shift+T with many windows (no rewrite loop, no yield), Figma tiled
  again after Alt+Shift+Space.
- [x] FX-01 — Live check of the new build (2026-10-21 22:18-22:48 UTC, user: "se sintió raro, no
  como antes ... Alt+K/Alt+J se siente raro, a veces cambia de workspace"). Measured, old build
  (22:18-22:42, 157 animations) vs new (22:42-22:48, 106): median 112 vs 114 fps, dropped
  frames per animation 1.71 vs 1.13, hitches 0.64 vs 0.39, reflow median 27 vs 21 ms: no
  regression. Focus call per app, both builds: OrbStack 208-228 ms median (max 318), every
  other app 7-100 ms. In the stacked column (OrbStack over Xcode/Figma) Alt+K focuses OrbStack
  in a pass with no motion, so the instant pass's synchronous focus held the ring (and cursor)
  ~200 ms. Fix: `focusRingLeadsFocus` (target not parked, on its planned frame within 0.5 pt)
  lets `instantPass` publish the ring before the focus call. The workspace switch is the
  user's binding: `Alt+J/K = focus-window-or-workspace-down/up` crosses to the workspace
  below/above from the column's last/first window (niri semantics); `focus-down/up` stay in
  the column. RED: compile (`FocusRingLeadTests`, 6).
- [x] FX-02 — Xcode showed SwiftUI "Invalid frame dimension (negative or non-finite)": the
  overview row computed its canvas from `proxy.size.width - labelWidth - spacing`, negative on
  a zero-size first layout pass (since WO-01). `overviewCanvasSize` clamps to empty. RED:
  compile (`testCanvasIsEmptyNotNegativeBeforeThePanelHasASize`). Bundles UI 356 (53 skipped)
  / Session 550 / POC 7 / Mac 19 / MacOS 107 / Core 2155, 0 failures; signed Debug build OK.
  LIVE PENDING: Alt+K onto OrbStack shows the ring at once; no warning when opening Alt+O.
- [x] FX-03 (`f0893b0`) — Overview opened under a still pointer resting on a Chrome tile: SwiftUI
  reported the hover at once and the selection left the focused window (user 23:02 UTC). Hover
  now selects only once the pointer moved since the panel opened (`WorkspaceOverviewModel`,
  injected `pointer`, default `NSEvent.mouseLocation`). RED: compile (2 tests).
- [x] FX-04 — Alt+Shift+T with 9 windows still overlapped (log 23:00:35: 7 `frameMismatch`,
  tiles `(1792,148,1,132)` for Xcode and Zed). Two causes: (1) BUG-3's proportional share gave a
  side with no known minimum 0 pt when its neighbour's need exceeded the split (RED:
  `testASideWithoutAMinimumIsNotSqueezedToNothing`, 970/1 instead of 691/279): each need now
  counts at least its nominal extent; (2) nine windows cannot fit one display. User decision
  (2026-10-21): refuse dwindle above a fixed configurable maximum. `[dwindle] max-windows`
  (1-32, default 6, Settings > Layout > Dwindle maximum windows): `setLayout(.dwindle)` refuses
  (`dwindleRefusal`, log `dwindle refused workspace=<id> windows=N max=M`); a dwindle workspace
  given more windows (arrival, move, rule, lower maximum on reload) returns to the strip in
  `WorkspaceManager.store`. Deviation from the option text the user picked ("a new window
  stacks on the focused one"): a dwindle tile holds one window, so the workspace returns to
  scrolling instead. RED: compile (`DwindleMaxWindowsTests`, 7). Smoke (throwaway, removed):
  six windows with the live minimums on 1800x1130 give tiles from 236x375 up, none at 1 pt; a
  7th window returns the workspace to scrolling with all 7. Bundles UI 358 (53 skipped) /
  Session 550 / POC 7 / Mac 19 / MacOS 107 / Core 2163, 0 failures; signed Debug build OK.
  LIVE (23:18:56): `dwindle refused workspace=2 windows=9 max=4` (the user had set 4); nothing
  moved, which read as a dead shortcut, hence FX-06.
- [x] FX-05 (`ef6dbe9`) — Performance check of the four builds of 2026-10-21 (log, per launch):
  median fps 112/113/108/114, dropped frames per animation 1.71/1.44/2.36/1.58, reflow median
  27/20/27/29 ms, overview open 36-44 ms, overview capture 153 ms before WO-02 vs 73-137 after:
  no regression (the C build's 68 `frameMismatch` were the 9-window dwindle tests, FX-04).
  Focus time per app moves with the app (OrbStack 208-221 ms in every build; Xcode 8-64 ms
  while it debugs Gio). Two defects found: WhatsApp/Figma learned 970x600 then 970x0, so the
  pair never confirmed and the width was learned again every launch; the 1 pt dwindle tiles had
  left 888 pt candidates for Tern/Slack/OrbStack (their column width) that one more such learn
  would confirm. Fix: `AppMinimumSizes` confirms width and height apart (`Axis`), a learn with 0
  on an axis leaves it alone; `learnedMinimum` ignores an axis whose request is below 100 pt;
  store format 3, format 2 keeps only confirmed pairs (drops the 888 candidates, keeps Xcode
  400x350). RED: `testWidthAndHeightAreConfirmedApart`, `testAValueSeenOnceThatDiffersReplaces
  TheCandidate` (updated: the confirmed height now counts), `testARequestTooSmallToMeanAnything
  IsNotLearned`. LIVE PENDING: two launches without `min size learned` for WhatsApp's width.
- [x] FX-06 — A refused Alt+Shift+T showed nothing. `ActionEffect.dwindleRefusal` →
  `SessionHost.onDwindleRefused` (main) → `NoticePanelController` (`GioUI/NoticePanel.swift`): a
  click-through, non-activating panel at `.statusBar`, centred 14% up the focused display's
  visible frame (`noticeFrame`), fades in 0.15 s, holds 2.2 s, fades out; made on first use, no
  work while hidden; a newer notice replaces the old (generation). `gio layout dwindle` answers
  `layout unchanged (workspace N has W windows; dwindle holds at most M, [dwindle] max-windows)`
  instead of "already dwindle". RED: compile (`ActionApplierTests` refusal tests,
  `NoticePanelTests`, 3). Visual: throwaway render of the real panel (removed). Bundles UI 361
  (53 skipped) / Session 552 / POC 7 / Mac 19 / MacOS 107 / Core 2167, 0 failures; signed Debug
  build OK. LIVE PENDING: Alt+Shift+T on the 9-window workspace shows the notice.
- [x] FX-07 (`3a671bb`) — User (2026-10-21 23:44): "OrbStack llegó un momento que no se
  renderizó y se vio su espacio vacío". Log: 25 `reconcile retry ... reason=busy ms=500` today
  (22 OrbStack), e.g. 23:43:23.954 a flight's dispatched write to OrbStack (busy activating, its
  focus takes ~210 ms) ended `readbackFailed(position/size,-25204)`, the overlay came down
  (`handoff waited ms=0 windows=0`), and the retry at 23:43:24.494 wrote it (`applied=1`): its
  slot showed bare desktop for ~540 ms. Fix: `retryBeforeHandOver` (latest outcome per window
  over the folded passes; transient failures only; visible or parked target) and
  `collectDispatchedWrites` writes them once more (`reconcile retry now ... reason=busy`) before
  the hand-over, while the overlay still covers the slot; the MM-11 backoff applies only if that
  write fails too. Cost: one window's write at the end of a flight, only after a busy failure
  (live: 5 ms). RED: compile (`TransientWriteRetryTests`, 3). Bundles UI 361 (53 skipped) /
  Session 552 / POC 7 / Mac 19 / MacOS 107 / Core 2170, 0 failures; signed Debug build OK. The
  maximize case (instant resize, app repaints late) was considered and dropped: the user saw
  OrbStack, and asked not to animate size changes. LIVE PENDING: rapid Alt+H/L across OrbStack
  never shows its slot empty; the log shows `reconcile retry now` instead of the 0.5 s retry.
- [x] FX-08 — User (2026-10-21): apps with transparency flicker when you enter them, while the
  image goes and the real app comes in. The capture shows the desktop unblurred through a
  see-through part (sidebar vibrancy, terminal background opacity) and the window's inactive
  look; the real window blurs what is behind it and turns active; the overlay left with a hard
  cut (only resized layers faded, SM-30). Fix: `snapshotLooksTranslucent` (at least 3 % of the
  64x64 coarse scan under alpha 0xF0; rounded corners stay well below), computed once per
  capture off the session queue (`CapturedSnapshot`, `SnapshotFreshRead`), kept as
  `SnapshotCacheEntry.translucent`; `snapshotHandoffFading(resized:translucent:layered:)` fades
  those layers over the real window (120 ms) like resized ones. Cost: one 64x64 draw per
  captured window (only on capture runs), one CA fade per translucent layer at hand-off. RED:
  compile (`SnapshotFreshTests`, `SnapshotCacheTests`). Smoke (throwaway, removed): a synthetic
  1800x1100 capture with rounded corners reads opaque, one with a 360 pt sidebar at 70 % reads
  translucent. Bundles UI 361 (53 skipped) / Session 552 / POC 7 / Mac 19 / MacOS 107 / Core
  2172, 0 failures; signed Debug build OK. LIVE PENDING: focusing the translucent app shows a
  soft hand-off (`snapshot handoff ... fade=120`), no flicker.
- [x] FX-09 — FX-08 was not enough (user: "aún pasa", recording 2026-10-21 19:22, 120 fps,
  frames 1.5-5 s of the OrbStack corner). OrbStack never moved; the menu bar shows the focus
  going Figma → OrbStack → Figma → OrbStack. Frame by frame: OrbStack frontmost while its
  window still looks inactive for ~8 frames (its own late repaint), then active; at the next
  flight's start the window turns inactive while OrbStack is still frontmost (the overlay's
  image, captured inactive, replaced the real window); after the hand-off, with Figma frontmost,
  the real OrbStack shows active for 3 frames, then inactive: the flicker. Cause: every visible
  window on an overlaid display was drawn as an image, moving or not, and a window's image
  rarely matches its active state at both ends of a focus change. Fix: still windows
  (`snapshotStillWindows`) get a see-through layer (image hidden, shadow masked to outside the
  window, ring and dim kept) and a backdrop hole at their frame, so the real window, with its
  own repaint timing, shows throughout; not paint-checked, never faded; a retarget that moves
  one replaces its layer with an image layer from where it stands. Fewer images drawn per
  flight. RED: compile (`SnapshotFlightPlanningTests`, `SnapshotFlightTests`, 2 + 1); one test
  that pinned no hole beside an opening window updated (the still neighbour is now a hole).
  Bundles UI 361 (53 skipped) / Session 554 / POC 7 / Mac 19 / MacOS 107 / Core 2173, 0
  failures; signed Debug build OK. Not visually verified (the overlay draws on the live
  desktop). LIVE PENDING: the same Alt+H/L across OrbStack and Figma, recorded: OrbStack never
  flips between looks; the ring still moves at once; no shadow pop around still windows.
- [x] FX-10 — Still flickering (user: "aún sigue pasando ... en tern ... toma captura sin
  fondo o transparencia"; recording 2026-10-21 19:55, 120 fps). Measured per frame on a patch
  of Tern's translucent pane: real window RGB (31.7, 40.4, 39.8) (wallpaper green through the
  blur); for ~200 ms at every Alt+H/L, (43.5, 43.5, 45.4) neutral grey; the ~200 ms windows
  match the flights in the log (`anim done ... duration=194-232ms`, `layers=2`: Figma and Tern
  both move, so FX-09 does not apply). The grey is Tern's own translucent tint composited over
  black: `SCStreamConfiguration.backgroundColor` defaults to black, so a desktop-independent
  window capture flattened every see-through pixel, the image never matched the window, and
  FX-08's alpha test never fired. Fix: window captures set `backgroundColor = .clear`; the
  image keeps its alpha, the overlay shows the backdrop through it, and FX-08 fades the layer
  at the hand-off. Debug `snapshot window translucent id=P:E` once per window. No test (an
  adapter setting; Core's translucency and fade decisions are tested); a capture probe from the
  terminal needs Screen Recording, so it was not run. Limit: the image shows the wallpaper sharp
  where the real window blurs it (a CA background blur on moving layers was not added: GPU cost
  per frame). Bundles unchanged (UI 361 / Session 554 / POC 7 / Mac 19 / MacOS 107 / Core 2173),
  0 failures; signed Debug build OK. LIVE PENDING: the log shows `snapshot window translucent`
  for Tern; during Alt+H/L its pane stays greenish instead of turning grey.

## Acceptance criteria
- Idle: no periodic wakeups from Gio except event delivery (verify with log + Activity Monitor).
- Motion: fewer AX calls per animation (reported in `anim done`/timing) and frame rate matches display.
- Maximize on a fast app grows smoothly with no overlap; slow apps unchanged.
- All 5 bundles green; signed build OK; docs updated.

## Applicable checks
- TDD: STRICT ON. Runner `swift test` (read all 5 "Executed" lines).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: UNAVAILABLE (gentle-ai trailing-space path defect; user chose continue).

## Routes
Read-only audit: delegated Explore (done). PA-01..PA-06: delegated writers, sequential.

## Progress
- 2026-09-29: audit done, document created. Next: user go-ahead, then PA-01.
- 2026-09-29: user approved in order. PA-01 + PA-02 done, pushed. Next: PA-03 + PA-05.
- 2026-09-29: PA-03 + PA-05 done, pushed. Next: PA-04.
- 2026-09-29: PA-04 done, pushed. Next: PA-06.
- 2026-09-29: PA-06 done, pushed. Next: user live check (idle energy, fps, maximize).
