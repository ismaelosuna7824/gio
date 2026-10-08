# Fluidity: slow apps, registration storms, unpainted windows

## Objective
Workspace switching and column motion must feel smooth: a slow app must not stall the
session, idle bookkeeping must not compete with animations, and a window Gio placed must be
painted.

## Problem (2026-10-08 UTC session 01:10-01:26, `~/.config/gio/gio.log`)
- 258 animations: 2.3% of frames dropped, concentrated on slow apps. Music (`slowest=Music`)
  hit the 251 ms Accessibility timeout 5 times; each time ~20 frames dropped and
  `anim done duration` went from 367 ms to 636 ms (median Music write 22 ms; Xcode p90 37 ms,
  max 82 ms). Cause (code map): `MotionPlayer.finish` and the final pass each waited up to
  300 ms on every motion lane, on the session queue, so the slowest app delayed the summary,
  the final pass and every queued hotkey.
- One unreadable Chrome element (pid 17232) was re-offered by focus adoption on every
  activation: 177 `window register retry` lines and 45 `gave up` in 16 min; Finder (desktop)
  29 more. Each round is several AX reads on the session queue while windows animate.
- User report: "while switching screens not all windows rendered, only one showed". Log at
  01:20:51: `render mismatch id=5683:2 app=Tern ax=(-887,8,1784,1114) ws=missing` then
  `render nudge ... fixed=false`: Gio placed Tern, the WindowServer had no on-screen entry for
  it, and the 1 pt position nudge did not bring it back. Seen before with Tern, Chrome, Brave
  and Activity Monitor.

## Scope (user choice 2026-10-08)
PF-A slow apps do not stall motion, PF-B stop the registration loop, PF-C recover windows that
do not paint. Not chosen: capping AX writes at 60 Hz.

## Decisions
- PF-A: no lane wait in `MotionPlayer.finish`; the final pass waits only for the apps it
  writes, for `finalPassMotionGrace` (100 ms). Apps still writing are deferred
  (`ReconcileReport.deferred`, pending frames discarded, trust dropped) and `DeferredSettle`
  runs one more final pass when they are idle (30 ms polls) or at 600 ms. A separate adaptive
  write rate was not added: the lane's latest-value slot already gives a slow app only the
  frames it can take (the overwrites are the `dropped` count); the measured stall was the
  end-of-motion wait.
- PF-B: an AX element whose retries all failed is skipped for 30 s
  (`WindowRegistrationRetry.abandonCooldown`), matched with `CFEqual`; other elements of the
  same app are unaffected.
- PF-C: a failed position nudge escalates once to a size nudge (1 pt narrower, then the
  target); only a failed size nudge makes the window render-unverifiable. No `AXRaise` (it
  would reorder windows on a passive path, HD-01).
- PF-F (reverted): a dim that stayed on and followed AX motions per tick (regions from Gio's
  sampled frames, stacking from one WindowServer query per motion, 120 ms crossfade of the
  two windows of a focus change). The user tried it live and preferred the previous look
  ("now the dim looks odd, before it felt better"), so the code went back to HEAD: the dim
  hides during motions (80 ms out, 150 ms in after the settle). Never committed.
- PF-G: `layout.center-focused-column` defaults to `on-overflow` (was `never`): a neighbour
  already in view only takes focus, the strip scrolls and centers only when the column does
  not fit next to the previous one. Chosen by the user after trying it live in Settings.

## Tasks
- [x] PF-A — Motion end and final pass no longer block on a slow app. Commit `74cafb4`.
- [x] PF-B — Abandoned registration elements cool down 30 s. Commit `7f098b4`.
- [x] PF-C — Size nudge after a failed position nudge. Commit `bad1275`.
- [x] PF-D — Enter in Chrome's address bar no longer moves the focus to a neighbour (live
  report 2026-10-08 with screenshot: "as if I pressed Alt+L / Alt+H"). Commit `43b8c76`. Log:
  every keystroke re-creates Chrome's suggestion popup, a non-resizable window admitted as
  floating (`discovery exclude pid=17232 app=Google Chrome float(notResizable)` +
  `window open id=17232:13..22`, 10 in 5 min). `registerNew` appended it as the FOCUSED last
  column; Enter destroyed it and `stripWindows` clamped the focus to the last column (the
  neighbour), and the reveal scrolled there. Two fixes: floating arrivals no longer take the
  strip's focus (OS focus adoption still follows a dialog the OS focuses), and
  `Workspace.stripWindows` keeps `focusedColumn` on a surviving focused window (latent: a
  column closing left of the focus left the index one column too far right). RED:
  `FloatingArrivalFocusTests` (focus went to the popup column 2, then to Ghostty) and
  `StripFocusTests.testClosingAColumnLeftOfTheFocusKeepsTheFocusedColumnOnTheFocusedWindow`
  (column 1, expected 0); GREEN; all bundles 0 failures (UI 250/53 skipped, Session 279,
  POC 7, Mac 19, MacOS 40, Core 1268); signed build SUCCEEDED. LIVE PENDING. Not addressed:
  a floating dialog the OS focuses and then closes still falls back to the last column until
  the next focus adoption re-adopts the app's main window.
  Same cause for the follow-up report "sometimes I only scroll and it switches to the
  neighbour": the running session (old build, started 01:10 UTC) registered Tern transient
  dialogs while the user worked (`float(dialog)`, `window open id=5683:23` at 01:48,
  `5683:24/25` at 01:52). `FloatingArrivalFocusTests` now covers `.dialog` as well.
- [x] PF-E — Transient windows no longer cost retry rounds (log, session 02:42-03:58 UTC:
  1730 `window register` lines in 76 min, 1702 from Chrome pid 17232, 363 give-ups, up to
  111 lines a minute; every round is AX reads on the session queue next to the animations).
  Cause: an element destroyed before it could be read read as `frameUnreadable` (4 retries)
  and a readable admission rejection (tooltip/popover, role not `AXWindow`) as
  `unclassified` (3 retries). Fix: `registrationFailure(elementGone:roleReadable:
  frameReadable:ignore:)` (GioCore) classifies `.gone` (role read returns
  `kAXErrorInvalidUIElement`) and `.rejected` (readable `notAWindow`, or `sheetOrPopover`),
  `WindowRegistrationRetry.delay` returns nil for both, `discoverSystemWindowAttempt`
  reports them (one extra role read on failure only), and `DiscoveryService` logs one debug
  `window register dropped ... reason=gone|rejected` and puts the element in the 30 s
  cooldown. RED: compile (`WindowRegistrationFailure` had no `gone`/`rejected`, no
  `registrationFailure`) for `WindowEventPolicyTests.testGoneAndRejectedElementsAreNeverRetried`,
  `testWhichFailuresAreDefinitive` and `RegistrationRetryGuardTests
  .testAGoneOrRejectedElementIsTriedOnceAndRejectedOnesCoolDown`; GREEN. LIVE PENDING: the
  `window register retry` rate with Chrome in use should drop to near zero.
  Commit `dd729b4`.
- [x] PF-G — `center-focused-column` defaults to `on-overflow`. RED:
  `CenterFocusedColumnModeTests.testDefaultIsOnOverflow` (got `never` for both the default
  section and a parsed config without the key); `ConfigTests.testDefaultsMirrorPlanExample`
  updated to the new default. Commit `a59f85d`. Existing configs keep their value.
- [~] PF-F — Dim follows motions instead of pulsing. Implemented, tried live by the user,
  reverted at their request (2026-10-08): the previous fade out/in looked better to them.
  No code left behind; see Decisions (PF-F).

## Evidence
- RED observed: PF-A `MotionPlayerTests.testSummaryLineNamesSlowestAppByWorstSingleWrite`
  (sink waited once, expected none; later the wait was removed from `MotionFrameSink`
  altogether); `TrustedFrameTests.testSettleDropsDeferredWindows` (deferred window still
  trusted). PF-B `RegistrationRetryGuardTests.testAnAbandonedElementIsNotRetriedUntilTheCooldownEnds`
  (compile: no `abandonCooldown`). PF-C tests were written before the code but their RED run
  was not recorded separately; `MotionLaneTests.testAHungMotionWriteDefersItsAppAndTheFinalPassGoesOn`
  and `DeferredSettleTests` were written with the implementation (not observed RED).
- GREEN: `swift test`, all bundles 0 failures: GioUITests 250 (53 skipped), GioSessionTests
  278, GioPOCTests 7, GioMacTests 19, GioMacOSTests 40, GioCoreTests 1266. Signed `xcodebuild`
  BUILD SUCCEEDED. `git diff --check` clean.
- LIVE PENDING: switch to and from the workspace with Music repeatedly and compare
  `anim done duration` and `settle deferred` lines; activate Chrome repeatedly and expect one
  retry round then `window register skipped` (debug); watch for `render nudge ... tier=size`.

## Progress
- 2026-10-08: log analysis, three fixes implemented and verified automatically; live check
  pending.
- 2026-10-08: PF-E (no retries for gone/rejected elements) and PF-G (on-overflow default)
  committed. PF-F implemented, tried live, reverted at the user's request (never committed).
