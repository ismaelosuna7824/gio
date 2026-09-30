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
