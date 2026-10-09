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
- PF-J (supersedes PF-G): `center-focused-column` defaults to `never` again (Niri's default).
  With `on-overflow`, any pair of columns that does not fit together (real minimum widths:
  WhatsApp 970, LoopOps 1024 on an 1800 pt screen; or the false 1068 of MM-05) re-centered
  the whole strip on every focus change between them, the "windows move when they should not"
  report of 2026-10-09. Chosen by the user after the MM-05/SM-23 build felt better live.
- PF-I: focus counts only when the target's app is frontmost (`NSWorkspace.frontmostApplication`)
  and its focused window is the target (`FocusLanding.judge`, GioCore). The actuator keeps
  `NSRunningApplication.activate()`, focuses and raises the window, then writes the app's
  `AXFrontmost = true` and re-checks every 5 ms for at most 50 ms (`FocusLandingCheck`); a miss
  throws `notFrontmost(frontmost=<pid>,ax=<AXError of the AXFrontmost write>)`. No hop to main:
  AppKit stays on the calling thread (lane / session queue) as before SM-12, because
  `NSRunningApplication` is documented thread-safe, `activate()` and `frontmostApplication`
  already ran on the session queue for months, and Gio's own pid never gets here (rule 4). The
  50 ms wait is on that thread only. Main never waits on a lane; its only `queue.sync` calls on
  the session queue are in `start` (`initialSync`, no keyboard intent pending yet; at worst one
  bounded 50 ms wait) and `shutdown` (never focuses). Repeated refusals are one per key press, not a re-send: they are kept and
  logged by the reconciler once per window per minute (`FocusFailureLogGate`, debug,
  `focus failed id= app= reason= suppressed=`); `foldSettle` logs only landed intents.

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
- [x] PF-J (`994a74d`) — `center-focused-column` defaults to `never`. RED:
  `CenterFocusedColumnModeTests.testDefaultIsNever` (got `onOverflow` for the default section
  and a parsed config without the key); `ConfigTests.testDefaultsMirrorPlanExample` (same).
  `ConfigTemplate` writes `"never"`; `docs/USER_GUIDE.md` default updated. Existing configs keep
  their value (the user's already says `"never"`).
- [~] PF-F — Dim follows motions instead of pulsing. Implemented, tried live by the user,
  reverted at their request (2026-10-08): the previous fade out/in looked better to them.
  No code left behind; see Decisions (PF-F).
- [ ] PF-H — `Alt+F` sometimes left the maximized window flush with one screen edge and
  twice the padding on the other, until a focus round trip re-centered it (user screenshot
  2026-10-08 05:05Z, Xcode; log `native zoom ... result=corrected verified=true`, so the
  frame matched a wrong target). Cause: the minimal reveal (`revealOffset` with
  `ensureVisible`) scrolled the column's bare range into view, flush with the screen edge;
  a maximized column is the viewport minus twice the padding, so it landed at `x = 2p` or
  `maxX = W`. The same flush edge happened to any neighbour scrolled in with `never` /
  `on-overflow`. Fix: `revealOffset(edgeMargin:)` reveals the range widened by the layout
  padding (bare range when that is wider than the viewport); `planDisplayLayout` passes
  `engine.config.padding`. RED: `RevealGeometryTests
  .testAMaximizedColumnRevealedFromEitherSideKeepsThePadding` (`minX 16` / `maxX 1800`
  from the left, `minX 0` from the right, expected 8 / 1792) and
  `testANeighbourScrolledInStopsAtThePaddingNotTheScreenEdge` (`maxX 1800`, previous column
  at 16). `CenterFocusedColumnModeTests` minimal-scroll expectations moved from 864 (flush)
  to 872 (padding kept). GREEN: Core 1318, Session 300, UI 250 (53 skipped), MacOS 40,
  Mac 19, POC 7, 0 failures; signed build succeeded. LIVE PENDING: `Alt+F` on a middle or
  last column shows the padding on both sides at once.
- [ ] PF-I (`fa27a03`, together with the snapshot renderer) — Keyboard focus from an unmanaged active app reaches the tiled window. Not
  committed (user asked for no commit). Live 2026-10-08 20:46 UTC: `hotkey focusLeft` then
  `focus intent id=5980:5 changed=true failed=false` (VS Code), yet the screenshot showed
  OrbStack (unmanaged, no tiled window) still active (menu bar OrbStack, keys not reaching
  VS Code until a click; `focus adopt source=activation id=5980:5` only at 20:46:08).
  `focusAXWindow` verified only the app's `AXFocusedWindow`, never that the app was frontmost.
  Also `focus intent id=31952:13 changed=false failed=true` 32 times (Xcode window).
  Log analysis of the 31952:13 lines: every one follows a `hotkey focusRight` onto the last
  column (e.g. 20:44:15-16: 11 presses, the last four land on 13 and give four failures;
  failures of one burst appear back to back because dispatched passes are folded together at
  the flight's settle); totals 588 `focus intent` lines for 594 focus-carrying hotkeys plus 7
  `focus window requested` and 4 `focus reassert`. So no re-send bug: `FocusIntent.take`
  consumes the target once per press (HD-01 holds), the window simply refuses focus.
  Apple documentation (read 2026-10-08):
  - Documented: `NSRunningApplication.activate(options:)` "attempts to activate"; with no
    options "the new app is activated only if there's no currently active application"
    (`activateIgnoringOtherApps` discussion); `activateIgnoringOtherApps` is deprecated since
    macOS 14. Cooperative activation (macOS 14, `activate(from:options:)`, `yieldActivation(to:)`):
    activation is a request the system may deny, and "only the active app can influence the
    activation context" by yielding first; Gio is never the active app here, so it cannot yield.
    `NSRunningApplication` "is thread safe, in that its properties are returned atomically", and
    its time-varying properties refresh per turn of the main run loop. `frontmostApplication` is
    "the app that receives key events". `kAXFrontmostAttribute`: "whether the application ...
    is active"; the SDK header and the docs do not say whether it is writable.
  - Inferred (not documented): writing `AXFrontmost = true` makes an AppKit app activate itself
    (other window managers rely on it); from a background thread `frontmostApplication`
    follows Gio's main run loop, which keeps turning (main never waits on lanes), so a landing
    can read late and log a false `notFrontmost` inside 50 ms (diagnostic only: `focusFailed`
    drives no retry); `activate()` and `NSWorkspace` reads are safe off main (they ran there
    before SM-12 without a crash); the old success for tiled-to-tiled focus came from
    `AXFocusedWindow`/`AXRaise` side effects in the target app, not from `activate()`.
  Decisions: see Decisions (PF-I). Changes: `FocusLanding`, `FocusLandingCheck`,
  `FocusFailureLogGate` (new `GioCore/Reconciliation/FocusLanding.swift`);
  `ReconcileReport.focusFailure` (diagnostic, outside equality) filled by `reconcile`,
  `collect` (`DispatchFocusStep.Outcome.failure`) and logged for `focusNow` too;
  `SystemWindowActionError.notFrontmost`, a failed `AXFocusedWindow` write now reports
  `writeFailed(AXFocusedWindow,<status>)` instead of a bare `focusRefused`; `focusSystemWindow`
  (gio-poc, main thread of a CLI) spins the run loop instead of sleeping. RED: compile
  (`ReconcileReport` had no `focusFailure`; no `FocusLanding`/`FocusLandingCheck`) for
  `FocusIntentTests.testFocusLandsOnlyWhenTheTargetAppIsFrontmostAndItsFocusedWindowMatches`,
  `testAnotherFrontmostAppIsNotFrontmostWithoutReadingTheWindow`,
  `testLandingCheckFinishesOnLandingAndRetriesOnlyWithinItsBudget`,
  `testAwaitedLandingStopsAtTheFirstLanding`, `testAwaitedLandingGivesUpAtTheBudgetWithTheLastReason`
  and `ReconcileFailureTests.testFocusGateLogsOncePerWindowPerMinuteAndCountsTheRest`; then,
  with the pure types in place and the reconciler unwired, 5 failures:
  `ReconcilerTests.testFocusFailureIsRecorded`, `testFocusFailureCarriesItsReason`,
  `testDispatchedFocusFailureCarriesItsReason` (`focusFailure` nil) and
  `ReconcileFailureTests.testRefusedFocusIsLoggedOncePerWindowPerMinuteWithItsReason` (no
  `focus failed` lines). GREEN: `swift test` all bundles 0 failures (UI 274 / 53 skipped,
  Session 349, POC 7, Mac 19, MacOS 49, Core 1469); `git diff --check` clean. Signed
  `xcodebuild` not run in this task. LIVE PENDING: with OrbStack (or another unmanaged app)
  active, `Alt+H`/`Alt+L` onto a tiled window makes that app frontmost (menu bar, keystrokes)
  without a click; the log shows `focus intent id=... changed=true`, or
  `focus failed ... reason=notFrontmost(frontmost=<pid>,ax=<status>)` if macOS still refuses
  (`ax` tells whether the `AXFrontmost` write was accepted). Also read the `reason` of the
  Xcode window 31952:13 the next time it refuses.

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
