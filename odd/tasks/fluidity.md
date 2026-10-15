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

## Scope (user choice 2026-10-11, OmniWM comparison)
Hiding and revealing windows (off-viewport columns, inactive workspaces, workspace switches)
and the AX motion should feel as fluid as OmniWM's. The user allowed private APIs with a
runtime probe and a fallback to the Accessibility-only path. Order: Fluidity first (this
file, PF-K onwards), then Move Edge, Dwindle and gestures (other branches). Reference: the
OmniWM evaluation (`HidingEval`): OmniWM turns `AXEnhancedUserInterface` off around write
batches, moves hidden windows with SkyLight transactions and follows with an AX write once
settled. OmniWM is GPL-2.0: read for behavior only, no code copied.

## Scope (user choice 2026-10-11, live renderer)
With the snapshot renderer the motion slides images of the windows: the user's log showed
`snapshot flight ... cacheAgeMs=3467..7108`, so the content was seconds old and the swap to the
real windows at the end showed ("se ve como que es una imagen"). OmniWM moves the real windows
(AX per tick for visible ones, SkyLight for hidden ones; `HidingEval`). The user chose a new
renderer `"live"` that moves the real windows, as the default (PF-O).

## Scope (user choice 2026-10-12, SkyLight removed)
After living with PF-L..PF-P the user chose to remove SkyLight completely and go back to what
Gio had before PF-L: the snapshot renderer by default, Accessibility as the only window
transport ("se sentía más fluido"). Kept: PF-K, PF-Q, PF-R, the trackpad gestures (their
frames now go through the Accessibility motion lanes), Dwindle, MM-06 and NC-14 (PF-S).

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
- PF-K: `AXEnhancedUserInterface` is switched off per app for one write batch and back on at
  its end (`EnhancedUIGuard`, pure, Core-owned `EnhancedUserInterfaceSwitch`). A reconcile,
  dispatched, pre-position or nudge lane is one batch (the lane epilogue restores, on the
  lane thread, while the lane still holds the app). A motion is one batch from its first frame
  to the app's final-pass lane, not one per frame: OmniWM restores after every mailbox drain,
  but a switch per frame would make Chromium rebuild its accessibility state up to 120 times
  a second, and the flight is short (~300 ms). Restore timing for VoiceOver users: a restore
  the app does not take (hung app) stays pending; the app's next batch ends with it, every
  settle retries it on the app's lane without waiting, and shutdown retries it waiting
  (bounded by the 0.25 s stall) before the quit restore. Only apps that read `true` are
  touched (one read per app per second at most, never while Gio has it off); Gio's own pid
  never (Core guard plus the adapter refuses it). No config key: with VoiceOver off nothing is
  written. Logs: pids only (`enhanced ui pid=N on=`, `restore failed`, `restored`).
- PF-L: hidden and revealed windows move through the private SkyLight WindowServer transport
  first (`SLSMainConnectionID`, `SLSTransactionCreate`, `SLSTransactionMoveWindowWithGroup`,
  `SLSTransactionCommit`, verified present on macOS 27.0.1 with a throwaway `dlsym` check that
  moved nothing; window ids from `_AXUIElementGetWindow`, read once at registration). All
  resolved with `dlopen`/`dlsym` at runtime; a missing one turns the transport off
  (`missing-symbols:<names>`). Config key `[behavior] skylight` (default `true`): `[behavior]`
  rather than `[animations]` because instant passes (animations off, the snapshot overlay's
  real-window pass) use it too. Which windows (pure `planWindowServerFirst`): parks of windows on
  a display now and reveals of windows on no display now; hidden-to-hidden and
  visible-to-visible moves stay on AX (nothing to see; only the app can lay out a visible
  window). Same-size pre-positions (workspace-switch risers, MM-04 far-side jumps, same-size
  NA-02 entries) are SkyLight-only; resizing ones stay on AX (SkyLight never resizes). AX stays
  authoritative (invariant 10): a moved window is pending in the reconciler's ledger until an
  AX write that followed that very move succeeds; pending windows are never skipped as trusted
  and are written even when the app already reports the target (it may report the
  WindowServer's frame without having acted on it). Quit and restore-all first write every
  pending window where SkyLight put it (`syncWindowServerMoves`), so the restore does not trust
  a stale app frame. SkyLight is called on the session queue (OmniWM calls it from the main
  actor; [INFERENCE] the main connection is usable from any thread; LIVE PENDING). No runtime
  probe in PF-L: every SkyLight move is followed by an AX write anyway, so a WindowServer that
  ignores the move only loses the speed-up. The probe belongs with per-tick SkyLight motion
  (PF-M), where an ignored move would freeze a flight.
- PF-M: with the AX renderer, flights that start or end hidden (no more than a parking sliver
  in any viewport on both axes; `isOnScreen` counted a window hanging 1 pt below a display with
  no Dock there as visible, so a stricter `showsOnScreen` is used for both PF-L and PF-M) and
  keep their size move through SkyLight, one transaction per tick for all of them, no AX write
  on ticks, the final pass following through the PF-L ledger. Visible-to-visible flights keep
  their AX lanes; windows hidden at both ends are still not animated (`planMotion`) and trusted
  ones are skipped by the final pass (PA-04). Runtime probe: the coordinator suggested checking
  the first instant park; rejected because its AX write follows at once and moves the window
  either way, and checking right after the commit could read a not-yet-applied transaction.
  Instead the probe observes real flights only (no extra move, nothing visible): before a tick's
  commit it reads the WindowServer bounds of up to two windows moved on earlier ticks, which no
  AX write touched: at a committed frame = verified; still at the pre-flight frame on 3
  observations = failed (the transport stops for the session and that flight continues on AX
  from the next tick; at 120 Hz a broken transport freezes at most ~25 ms of one flight).
  Display link for the AX motion: not adopted (main-thread hop per tick, coupling to main
  stalls); the SkyLight per-tick path removes the app latency for hide and reveal flights.
- PF-N (with TG-05, `trackpad-gestures.md`): the transport's final word. Live 2026-10-11 after
  trackpad swipes (per-tick SkyLight on the settle), apps reported windows at their targets
  while the WindowServer drew them 33 and 1832 pt to the left, and no Accessibility write or
  nudge moved them. `reconcile` now ends every followed-up SkyLight move with one more
  transaction to the frame the app took (`WindowReconciler.alignWindowServer`, not recorded in
  the ledger: the app holds that frame), limited to windows the pass folded (a newer move is
  never undone); `collect` does not align (a newer dispatched pass may already have written
  the window). The render check moves a drawn mismatch through SkyLight to the app's frame
  before any nudge (`render repair id= app= via=skylight fixed=`). Cost: one extra transaction
  per pass that followed SkyLight moves (`skylight aligned windows=N`, debug).
- PF-O: renderer `"live"` (default; `"snapshot"` and `"ax"` stay). It is the motion player
  with `planMotionTransports(..., renderer: .live)`: every flight that keeps its size moves
  through SkyLight, visible-to-visible included, one transaction per tick for all of them,
  through the existing `submitWindowServerMotion` path (the one PF-M and the gesture pump use;
  nothing new talks to SkyLight). Split chosen: flights that change size (first-frame shrink,
  focused grow at start, interpolated sizes) stay on the AX motion lanes with
  `AXEnhancedUserInterface` off (PF-K). Rejected: an AX size write followed by SkyLight
  position moves for the same window, because the app answers an AX write with its own
  position-and-size commit from its belief, which would race the WindowServer moves (and
  SkyLight never resizes). Also rejected: OmniWM's per-tick AX for visible windows (that is
  the `ax` renderer, slow apps lag). Settle: PF-M/PF-N unchanged (final pass writes the ledger's
  pending windows through AX, then `alignWindowServer`); the driver cancels its timer before
  the final pass, so no tick commits after it. Mouse down: the flight stops (no final pass)
  with the windows pending where SkyLight left them; the instant pass after the release writes
  and aligns them. Not added: an AX write of the pending windows at the mouse-down itself
  (it would block the session queue up to the stall timeout on the click, and the release pass
  fixes the app's belief anyway). [INFERENCE] During the press an app whose belief is stale
  could misplace something it positions from its own frame (a tab drag); LIVE PENDING (15j e).
  Fallback: `effectiveRenderer(config:permission:windowServer:)` gives `.ax` when the transport
  is not available (config off, missing symbols, probe failed), logged as
  `renderer effective=ax reason=skylight-unavailable`; Diagnostics shows Live or Fallback with
  the skylight reason, the Overview's Motion tile Live or "Live needs SkyLight". Logs: `anim
  done ... renderer=live` with `hitches` = timer ticks more than 1.5 intervals after the
  previous one (same threshold as the snapshot display-link hitches); AX lines are unchanged.
  Screen Recording is now only for the overview thumbnails, the snapshot renderer and the close
  ghost (README, onboarding, Overview copy).
- PF-P (2026-10-12, the live renderer never ran): every session since `b2ed03e` logged
  `skylight probe result=failed` within ~120 ms of its first flight, then `renderer
  effective=ax reason=skylight-unavailable` for the rest of the session (02:23:53.772Z, 27 ms
  into the second three-finger scroll, i.e. three drains; 02:49:57.175Z, the first `focusLeft`,
  22 ms after Safari's activation event). The three suspects, checked:
  (1) readback latency: refuted by measurement. A throwaway helper in `/tmp` (not committed)
  opened its own 160x90 non-activating floating `NSPanel` in an accessory process (Gio manages
  `.regular` apps only) in the display's corner for 2 s and moved it through
  `SLSTransactionCreate`/`SLSTransactionMoveWindowWithGroup`/`SLSTransactionCommit` every
  8.3 ms, 40 commits, while a thread sampled `CGWindowListCopyWindowInfo` and
  `SLSGetWindowBounds` every ~1 ms: commit to readback median 1.2 ms, max 1.4 ms from the
  main thread; median 1.0 ms, max 2.2 ms from a background queue (Gio's session-queue case);
  a Gio-style look just before each commit always showed the previous commit. Three ticks
  (25 ms) were already >10x that. (2) wrong id or coordinates: refuted by the failure itself,
  which requires the readback, converted to Cocoa, to match Gio's own pre-flight frame within
  2 pt (ids and the flip agree). (3) the moves did not take effect for those ticks: the
  remaining explanation. The same helper moving the panel from a second process (no
  Accessibility trust, `.prohibited` and `.accessory` policies, main thread and background
  queue) found foreign moves silently dropped (40 transactions, the panel never moved) and
  `SLSMoveWindow` returning 1000 (`kCGErrorFailure`). Whether Gio's connection (Accessibility
  trusted) may move other apps' windows could not be measured without running Gio or
  borrowing its TCC grant; [INFERENCE] two mechanisms fit the log: the WindowServer refusing
  the moves outright, or an app re-asserting its own frame (Safari was activated 22 ms before
  the 02:49 verdict; PF-O already notes apps commit their belief). Not b2ed03e itself: it
  changes no probe or commit path, only adds alignment transactions after Accessibility writes.
  The 22:53Z `result=verified` (the only one, during a gesture) is not proof either: the old
  probe verified on a drawn origin within 2 pt of any committed frame, and a scroll's first
  drain can commit 2 pt from the start (write tolerance 1 pt), so a window that never moved
  verified it. Probe defects fixed: false verification by a move within the slack; one 25 ms
  trial decided the whole session; stuck looks were counted against the frame the window had
  before its first move ever (not per flight), so an Accessibility write landing at a
  committed frame verified it and stale looks across flights added up; no evidence in the
  log. New rules (pure, `WindowServerProbe`): verified = drawn at a commit more than 2 pt from
  the flight's start, or drawn moved since the first look by the offset between two commits
  (coordinate-space independent); stuck = drawn unchanged since the first look while a commit
  at least 50 ms old lies away from every frame it could have shown then; three consecutive
  stuck looks fail the trial (a look elsewhere resets); evidence per flight (250 ms pause
  starts over; the reconciler forgets windows it moves any other way: `reconcile`,
  `dispatch`, `preposition`, `syncWindowServerMoves`, `alignWindowServer`, `nudge`). A failed
  trial turns SkyLight off until a retry 2 s later (600 s after later failures), state
  `retrying` (`skylight available=true reason=probe-retrying`); verdicts log their numbers.
  Cost of a refused transport: one flight frozen ~75 ms at 120 Hz per trial (it was ~25 ms,
  once). Rejected: OmniWM's explicit probe move of a foreign window (Gio's probe never moves a
  window by itself, PF-M); re-verifying after `verified` (a mid-session refusal would freeze
  flights until the final pass; not observed, left out).
- PF-Q (smoothness, both player renderers): the motion's ticks run on the session queue,
  which is also where FI-06 raised the focused window at every motion start and retarget.
  `focusAXWindow` activates the app and polls until it is frontmost: in the 02:49 session
  `hotkey focusLeft` to `focus now` took 17, 22, 18 and 12 ms for four presses (57.055/.072,
  .201/.223, .352/.370, .475/.487), Xcode and Safari the slowest. The first tick of each flight
  and the next tick of each retarget waited that long, and the elapsed-time sampling then jumped
  the spring forward (1.5-5 frames at 120 Hz). Decision: `WindowReconciler.focusSoon` runs the
  raise on a serial focus queue and returns at once; submission order is kept; refusals log
  through the PF-I gate (now behind a lock); `reconcile` waits up to 300 ms for pending ones
  before its own focus so the final pass stays the last word. `focus now ... failed=` became
  `focus now ... async=true`. `dispatch`'s focus step (snapshot overlay passes) does not wait:
  motion-start focus runs only for player motions, and a snapshot pass right after one would
  focus the same logical target. Other jank sources checked: the tick itself makes no AX call,
  reads nothing per tick except the probe's two `CGWindowListCopyWindowInfo` reads while a trial
  runs, and logs nothing; the focus ring hop to main is async. Not done: display-link-driven
  ticks (a `CADisplayLink` needs a run loop thread and a hop to the session queue per frame;
  the measured stalls are session-queue work, which a display link would wait behind just the
  same; the strict `DispatchSourceTimer` already keeps absolute deadlines, no drift).
- PF-R (metrics to compare the renderers): live lines already had `hitches`, but `dropped` there
  counts only the resizing windows' lane drops (nearly always 0), not frames the timer missed,
  so a live line could not be held against a snapshot line (`dropped` = expected minus
  presented) or an AX line (no `hitches`). Every player run (live and AX) now reports
  `missed=M` (sum over ticks of round(gap / interval) - 1) and `hitches=H` against the timer's
  interval; `dropped` keeps its meaning so older AX lines stay comparable. Snapshot lines are
  unchanged.
- PF-S (2026-10-12, supersedes PF-L, PF-M, PF-N/TG-05, PF-O and PF-P): SkyLight and the live
  renderer are removed. Evidence: a live probe on this Mac (10 SkyLight commits moving another
  app's window to x=-48) left the window at x=8, which fits PF-P's finding that the live
  renderer never ran (`skylight probe result=failed` in every session since `b2ed03e`) and the
  TG-05 drift; every SkyLight path was dead weight that cost a frozen ~75 ms per probe trial,
  extra follow-up writes (pending windows written even when the app reported the target) and
  the PF-N alignment transactions. The user also found the snapshot default smoother. Clean
  cutover, no flag: renderer kinds are `snapshot` (default) and `ax` again
  (`effectiveRenderer(config:permission:)`); the reconciler, the motion player and the render
  check are back to their pre-PF-L behaviour (render check: position nudge, then the PF-C size
  nudge); `_AXUIElementGetWindow` goes too (nothing kept needs the window id: native zoom and
  the snapshot capturer match WindowServer windows by frame). Old configs keep loading:
  `renderer = "live"` gets the ordinary unknown-value warning and the snapshot default,
  `[behavior] skylight` the ordinary unknown-key warning. Gestures: `GestureFramePump` hands
  every changed window to its app's Accessibility motion lane (one submission per app per
  drain, latest frame wins); the release settle stays on the motion player with the release
  velocity whatever the renderer. PF-R stays for AX runs (`missed=`/`hitches=`); PF-Q is
  unchanged.
- PF-T (2026-10-15, user: "a WM running all day must not slow the Mac down or use many
  resources"): measured first, fixed only the two biggest in-process costs. Baseline (Debug
  build, ~100 s of normal use): 7.6 % of a core; at rest ~0.1-1.5 %, ~0.1 wakeups/s, 67 MB
  footprint plus ~140 MB reclaimable "Malloc Large". `sample` (90 s, running self-time only):
  13 % in `snapshotDrawSamples`, 8.5 % in `LauncherAppCatalog.scan` (5 % drawing icons), the
  rest SwiftUI/Core Animation of the open Settings window, captures and AX.
  1. Snapshot sampling drew each capture into another colour space (deviceRGB for the blank
     grid, sRGB for the fill and strips). CoreGraphics converts the WHOLE image first (12-25 ms
     for a 3600x2300 capture, once per space and per crop) and keeps the converted copy (~33 MB
     per capture in the footprint: throwaway benchmark, 8 captures 3 MB -> 269 MB). Now the
     samples are drawn in the image's own colour space and layout (no conversion) and only the
     few sampled pixels are converted. Same pixels and colours (benchmark: 32x64 sRGB samples
     identical; one of 25 grid samples picked a neighbouring pixel at a rectangle edge, which
     the blank test does not care about); 31.7 ms -> 0.23 ms per capture, 269 MB -> 19 MB.
  2. Every app launch redrew the icon of every installed app. A refresh now draws only bundles
     that are new or whose Info.plist changed (`launcherIconsToDraw`); the others keep their
     icon. Log: `launcher appsReady ... drawn=N`.
  Not changed (measured small or inherent): typing captures (SCK, 159 samples/90 s after the
  fix; a per-window floor would trade freshness of the flight image), the multitouch callback
  (frames are already gated by finger count in the mailbox), SwiftUI work (only while Gio's
  window is open; `pollWhileVisible` stops with it).

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
- [x] PF-K (`5a54258`) — `AXEnhancedUserInterface` off around write batches (reconcile, dispatched,
  pre-position, nudge and motion lanes), restored after the batch, the final pass, the settle
  or shutdown; never for Gio's own pid. New `GioCore/Reconciliation/EnhancedUserInterface.swift`
  (`EnhancedUserInterfaceSwitch`, `EnhancedUIGuard`), `LaneExecutor` lane `epilogue`,
  `WindowReconciler(enhancedUI:ownPID:)`, `pendingEnhancedUIRestores`, `restoreEnhancedUI`;
  adapter `GioMacOS/Accessibility/EnhancedUserInterface.swift`; `SessionHost` wires it, retries
  in `finishSettle` and `shutdown`. RED: compile (`EnhancedUIGuard`,
  `EnhancedUserInterfaceSwitch` not found; `WindowReconciler` had no `enhancedUI:ownPID:`) for
  `EnhancedUserInterfaceTests`; after the first GREEN the motion batch moved from one switch per
  lane drain to one per flight: RED again by compile (no `pendingEnhancedUIRestores`) for
  `testAMotionKeepsItOffUntilTheAppsFinalPassLane` and
  `testTheSettleRestoresAMotionAppThatTheFinalPassDidNotVisit`. GREEN: Core 1688 (+16), Session
  393, UI 306 (53 skipped), MacOS 84 (+1, `testEnhancedUserInterfaceSwitchRefusesGiosOwnPid`,
  written with the adapter, not observed RED), Mac 19, POC 7, 0 failures; signed `xcodebuild`
  BUILD SUCCEEDED; `git diff --check` clean. LIVE PENDING: checklist
  15g in `docs/TESTING.md` (VoiceOver on: Chrome/Electron motion fluid, VoiceOver still reads
  every app after motions and after Quit; a stopped app logs `restore failed` then `restored`).
- [x] PF-L (`a3ea8d3`) — SkyLight WindowServer transport for parks, reveals and same-size pre-positions,
  AX follow-up, config key and status. New `GioCore/Reconciliation/WindowServerTransport.swift`
  (`WindowServerMove`, `WindowServerMover`, `WindowServerTransportStatus`,
  `windowServerTransportStatus`, `WindowServerStatusLogGate`, `planWindowServerFirst`,
  `WindowServerLedger`); `WindowReconciler(windowServer:)`, `windowServerEnabled`,
  `reconcile/dispatch(windowServerFirst:)`, pre-position split, `windowServerPending`,
  `syncWindowServerMoves`; `BehaviorSectionConfig.skyLight` (`[behavior] skylight`, template);
  `SessionFacts.windowServer`, `SessionFactsBuilder` logs `skylight available= reason=`;
  Diagnostics Renderer card line; adapter `GioMacOS/WindowServer/SkyLight.swift`
  (`SkyLightSymbols`, `SkyLightWindowMover`, `windowServerOrigin(of:flip:)`), actuator
  `windowServerID(of:)`/`verticalFlip`; `SessionHost` loads it with the actuator and passes
  `windowServerFirst` in instant and dispatched passes. RED (compile): `WindowServerTransportTests`
  (no `planWindowServerFirst`, `WindowServerMove`, `WindowServerMover`,
  `windowServerTransportStatus`, `WindowServerStatusLogGate`), `ConfigTests`
  (`BehaviorSectionConfig` had no `skyLight`), `SessionFactsBuilderTests` (no
  `windowServerStatus:`; `SessionFacts` had no `windowServer`), `SkyLightTests` (no
  `SkyLightSymbols`, `SkyLightWindowMover`, `windowServerOrigin`, actuator `windowServerID`);
  `AdvancedPresentationTests.testRendererCardNamesTheHiddenWindowTransport` was written in the
  same RED batch (its RED was the shared `SessionFacts` compile error). GREEN: Core 1705 (+17),
  Session 394 (+1), UI 307 (+1, 53 skipped), MacOS 89 (+5), Mac 19, POC 7, 0 failures; signed
  `xcodebuild` BUILD SUCCEEDED; `git diff --check` clean. LIVE PENDING: checklist 15h in `docs/TESTING.md` (startup line, atomic hide/reveal with
  animations off and under the overlay, instant switch start with the AX renderer, apps know
  their frames afterwards, `skylight = false` fallback, Quit restores windows mid-switch).
- [x] PF-M (`ea96c2c`) — Hide and reveal flights move through SkyLight per tick, with a runtime probe.
  New `GioCore/Animation/MotionTransport.swift` (`MotionTransport`, `planMotionTransports`),
  `WindowAnimation.transport` (kept by `springing`), `MotionFrameSink.submitWindowServerMotion`
  (default: nothing moved), `MotionPlayer` routes window-server frames in one batch per tick
  and falls back to AX per window; `WindowServerProbe`, `WindowServerProbeState`,
  `windowServerTransportStatus(...probe:)`, `showsOnScreen`; `WindowReconciler
  .submitWindowServerMotion`, `windowServerProbe`; `WindowServerMover.frames(of:)` (adapter:
  `CGWindowListCopyWindowInfo` bounds only); `SessionHost` plans transports after the size
  schedules and republishes the facts when the status changes. RED (compile):
  `WindowServerMotionTests` (no `planMotionTransports`, `WindowServerProbe`,
  `MotionTransport`, `submitWindowServerMotion`, `windowServerProbe`, probe-aware status).
  GREEN after the rebase onto MM-06: Core 1729 (+11), Session 400, UI 307 (53 skipped), MacOS
  89, Mac 19, POC 7, 0 failures; signed `xcodebuild` BUILD SUCCEEDED; `git diff --check` clean.
  LIVE PENDING: checklist 15h (glide of leaving/entering columns and switch
  drop/rise with Chrome and Electron, `skylight probe result=verified`, fallback).
- [x] PF-N — WindowServer aligned with the app after every followed-up SkyLight move, SkyLight
  render repair before the nudges. Commit `b2ed03e`. Recorded and evidenced as TG-05 in
  `trackpad-gestures.md`. LIVE PENDING: checklists 15h and 15i (l).
- [x] PF-O (`4443c13`) — Live renderer (real windows through SkyLight per tick, resizing windows on AX), the
  default. Changes: `RendererKind.live` (default in `AnimationsSectionConfig`, template, parser
  messages), `effectiveRenderer`/`rendererReason`/`RendererLogGate` take `windowServer:`,
  `planMotionTransports(..., renderer:gestureSettle:)` (replaces `moveVisible:`),
  `MotionPlayer.start(_:renderer:frameInterval:)` (summary renderer and hitches),
  `MotionDriver.start(_:sink:renderer:)`, `SessionFactsBuilder` (renderer line after the
  transport status), `SessionHost` (effective renderer per pass, `motionPass` renamed from
  `axMotionPass`), Diagnostics Renderer card, Overview Motion tile, Settings > Animations >
  Renderer ("Live (real windows)", Default), onboarding/Overview Screen Recording copy; docs:
  README (Animation, Why Screen Recording, Private APIs), USER_GUIDE (`renderer`, `skylight`,
  example, Animations row), ARCHITECTURE (PF-O bullet, renderer choice, display link, logs),
  TESTING (15j, 15b/15h/15i, `renderer effective` and `anim done` rows). RED (compile, observed
  in `GioCoreTests/RendererSettingTests`: `RendererKind` had no `live`, `effectiveRenderer`/
  `rendererReason`/`RendererLogGate.line` no `windowServer:`; the same batch held
  `WindowServerMotionTests.testTheLiveRendererMovesEverySameSizeFlightThroughTheWindowServer`,
  `testALiveRunNamesItsRendererAndCountsLateTicks`, `testALiveRetargetKeepsTheSpringVelocityAndTheTransport`
  (no `renderer:` on `planMotionTransports`/`MotionPlayer.start`),
  `LiveRendererSettleTests` (settle ordering; click mid-flight), `MotionDriverTests
  .testALiveFlightLogsItsRendererAndHitches`, `SessionFactsBuilderTests
  .testLiveFallsBackToAXWithoutSkyLightAndSaysWhy`, `AdvancedPresentationTests
  .testRendererCardShowsLiveOrItsFallback`, `OverviewPresentationTests.testMotionSummary`; the
  build stopped at the Core errors, so the Session and UI compile errors were not printed
  separately). One existing expectation moved with the default:
  `SettingsPresentationTests.testAnimationsFormRoundTripsConfigAndBuildsEdits` (`.snapshot` to
  `.live`, failed once after GREEN). GREEN: `swift test` all bundles 0 failures: UI 312 (+1,
  53 skipped), Session 432 (+4), POC 7, Mac 19, MacOS 95, Core 1886 (+4);
  `GioUITests.LauncherPanelAnimationTests.testTheSlideInLandsOnTheRequestedFrame` passed in
  both runs this time. Signed `xcodebuild` BUILD SUCCEEDED; `git diff --check` clean.
  LIVE PENDING: checklist 15j in `docs/TESTING.md` (the user's config says
  `renderer = "snapshot"`, so switch it in Settings > Animations > Renderer first).
- [x] PF-P — The SkyLight probe judges by evidence that survives latency, small moves,
  coordinate spaces and other moments, and a failure retries instead of ending the session's
  live renderer. Commit `ab3b0fe`. Changes: `WindowServerProbe` rewritten (timed
  `moved(...at:)`/`observe(_:at:)`, `forget(_:)`, `refresh(at:)`, `trial`, `isTrialRunning`,
  `readbackAllowance`, `retryDelays`), `WindowServerProbeVerdict` (log line with evidence),
  `WindowServerProbeState.retrying`, status reason `probe-retrying`; `WindowReconciler`
  (probe on its clock, verdict logged, `probeForget` on every non-flight move). RED (compile):
  `swift build --build-tests` failed `cannot find type 'WindowServerProbeVerdict' in scope`
  (`WindowServerProbeTests`: three-ticks-late readback verified, late-within-allowance
  verified, ignored moves fail only after the allowance with evidence, 2 pt move does not
  verify, offset readback verifies by translation and fails when stuck, direct match line,
  moved readback resets the count, forgotten window, stale flight starts over, retry and
  back-off, `probe-retrying` status; `WindowServerMotionTests`: failure after the allowance
  then retry through the reconciler, an Accessibility write makes the probe forget). GREEN:
  `swift test` all bundles 0 failures: UI 312 (53 skipped), Session 436, POC 7, Mac 19, MacOS
  95, Core 1916 (+13); signed `xcodebuild` BUILD SUCCEEDED. LIVE PENDING: checklist 15h/15j
  (`skylight probe` lines).
- [x] PF-Q (`a303d9b`) — The motion-start focus runs off the session queue, so it no longer holds the first
  tick of a flight or a retarget. Changes: `WindowReconciler.focusSoon`/`waitForFocusIdle`
  (replace `focusNow`/`FocusNowResult`), focus queue, locked PF-I gate, `reconcile` waits for
  pending focus before its own; `FocusCoordinator.focusAtMotionStart` takes a non-returning
  closure and logs `focus now ... async=true`; `SessionHost.motionPass` calls `focusSoon`. RED
  (compile): `swift build --build-tests` failed `value of type 'WindowReconciler<...>' has no
  member 'focusSoon'` / `'waitForFocusIdle'` (`MotionStartFocusTests`: does not hold the
  caller, ordered and before the settle focus, refusal logged once; `ReconcilerTests` and
  `ReconcileFailureTests` ported from `focusNow`; `FocusCoordinatorTests` expects the new
  line). GREEN: `swift test` all bundles 0 failures: UI 312 (53 skipped), Session 436, POC 7,
  Mac 19, MacOS 95, Core 1919 (+3); signed `xcodebuild` BUILD SUCCEEDED. LIVE PENDING:
  checklist 15j (f), compare the gap from `hotkey` to the next tick.
- [x] PF-R (`95417ba`) — `anim done` of live and AX runs reports `missed=M hitches=H`. Changes:
  `MotionSummary.missed` (line, equality), `MotionPlayer` counts missed intervals,
  `MotionDriver.start` passes the timer interval for AX runs too. RED (compile): `swift build
  --build-tests` failed `value of type 'MotionSummary' has no member 'missed'`
  (`WindowServerMotionTests.testAPlayerRunNamesItsRendererAndCountsLateTicksAndMissedFrames`,
  replacing `testALiveRunNamesItsRendererAndCountsLateTicks`; `MotionDriverTests
  .testAPlayerFlightLogsItsRendererHitchesAndMissedFrames`, replacing
  `testALiveFlightLogsItsRendererAndHitches`). GREEN: `swift test` all bundles 0 failures: UI
  312 (53 skipped), Session 436, POC 7, Mac 19, MacOS 95, Core 1919; signed `xcodebuild` BUILD
  SUCCEEDED. LIVE PENDING: checklist 15j (compare `missed`/`hitches` across renderers).
- [x] PF-S (`3511e90`) — SkyLight and the live renderer removed; snapshot is the default renderer again.
  Deleted: `GioMacOS/WindowServer/SkyLight.swift`, `GioCore/Reconciliation/WindowServerTransport.swift`
  (mover protocol, status, ledger, probe, `planWindowServerFirst`), `GioCore/Animation/MotionTransport.swift`
  (`planMotionTransports`), their tests (`SkyLightTests`, `WindowServerTransportTests`,
  `WindowServerMotionTests`, `WindowServerProbeTests`, `WindowServerAlignmentTests`,
  `LiveRendererSettleTests`). Restored to their `5a54258` state: `Animation.swift` (no
  `transport`), `RendererChoice.swift`, `RenderVerification.swift` and `RenderVerifier.swift`
  (no `planRenderRepairs`), `AXWindowActuator.swift` (no window number or flip accessor),
  Onboarding, Overview Motion tile and Animations renderer card; `Reconciler.swift` is
  `5a54258` plus PF-Q. Edited: `MotionFrameSink` (no `submitWindowServerMotion`),
  `MotionPlayer.start(_:frameInterval:)`, `MotionDriver.start(_:sink:)`, `GestureFramePump`
  (lanes only), `[behavior] skylight` and `RendererKind.live` gone (config, parser, template),
  `SessionFacts.windowServer` and the `skylight available=` log gone, Diagnostics Renderer
  card, `SessionHost` (no transport loading, status, `windowServerFirst`, transport planning,
  `syncWindowServerMoves`; `axMotionPass` again); docs: README (Private APIs: MultitouchSupport
  only; Animation and Why Screen Recording back to the snapshot default), USER_GUIDE,
  ARCHITECTURE (invariant 10 and the WindowServer transport section removed), TESTING (15h and
  15j removed, their PF-Q/PF-R checks moved to row 5, 15i through Accessibility), AGENTS.md
  (rule 11 removed). Migrated tests: PF-R's player test to `MotionPlayerTests`, the driver's to
  `MotionDriverTests.testAFlightLogsItsHitchesAndMissedFrames`, the gesture sink tests to lanes
  (`GestureFramePumpTests`, `GestureControllerTests`), the facts builder's renderer test to the
  snapshot default. RED (compile): `swift build --build-tests` failed `missing argument for
  parameter 'windowServer' in call` in the restored `RendererSettingTests` (with
  `testRemovedLiveRendererWarnsAndKeepsTheSnapshotDefault`, `ConfigTests
  .testRemovedSkyLightKeyWarnsAsUnknown` and the lane-only `GestureFramePumpTests` in the same
  batch). GREEN: `swift test` all bundles 0 failures: UI 310 (53 skipped), Session 428, POC 7,
  Mac 19, MacOS 90, Core 1869; signed `xcodebuild` BUILD SUCCEEDED; `git diff --check` clean.
  LIVE PENDING: checklist 15b (snapshot default), 15i (gestures
  through Accessibility: the strip follows the fingers, no `render mismatch` after a settle) and
  row 5 (PF-Q/PF-R on `renderer = "ax"`).
- [x] PF-T (`ca602f8`) — Resource use: snapshot sampling without whole-image colour
  conversion (`snapshotDrawSamples` + `snapshotNativeSamples`, GioMacOS) and launcher icons
  drawn only for new or changed bundles (`launcherIconsToDraw`, `LauncherScanResult.stamps`,
  GioUI; `drawn=` in `launcher appsReady`, docs/TESTING.md). RED (compile):
  `LauncherCatalogRefreshTests.testARefreshDrawsOnlyNewOrChangedIcons` ("cannot find
  'launcherIconsToDraw' in scope"). The sampling change keeps its results (existing
  `GioMacOSTests` green; equality and timing proved by a throwaway benchmark, Decisions PF-T).
  GREEN: `swift test` all bundles 0 failures: UI 312 (53 skipped), Session 481, POC 7, Mac 19,
  MacOS 95, Core 1963; signed `xcodebuild` BUILD SUCCEEDED; `git diff --check` clean.
  Live (Debug build, Gio window closed, ~90 s of normal use, same `sample` method): Gio CPU
  7.6 % -> 2.7 % of a core (2.54 s in ~93 s); `snapshotDrawSamples` 669 -> 31 samples,
  colour conversion (`vImageConvert_AnyToAny`) 580 -> 2, launcher scan 442 -> 0; footprint
  67 MB with no reclaimable "Malloc Large" left (was ~140 MB). The baseline had Settings open,
  so the overall CPU figure is not like for like; the per-function samples are.

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
- 2026-10-11: PF-K (`5a54258`, `AXEnhancedUserInterface` off around write batches) and PF-L
  (`a3ea8d3`, SkyLight hide/reveal with AX follow-up, `[behavior] skylight`) committed on
  `feat/fluidity-skylight`; all bundles green, signed build succeeded; both LIVE PENDING
  (checklists 15g and 15h). Branch rebased by the coordinator onto MM-06 (hashes above are the
  rebased ones). PF-M (per-tick SkyLight motion and the runtime probe) implemented; display
  link for the AX motion not adopted (Decisions, PF-M).
- 2026-10-11: PF-O (`4443c13`, live renderer, default) committed on `feat/live-renderer`; all
  bundles green, signed build succeeded; LIVE PENDING (checklist 15j).
- 2026-10-12: PF-P (`ab3b0fe`, probe evidence, retries), PF-Q (`a303d9b`, motion-start focus
  off the session queue) and PF-R (`95417ba`, `missed`/`hitches` for live and AX) committed on
  `main`, not pushed; all bundles green, signed build succeeded; LIVE PENDING (checklists 15h,
  15j). The `skylight probe` lines of the next live session decide whether this Mac takes
  SkyLight moves of other apps' windows at all (Decisions, PF-P).
- 2026-10-12: PF-S (`3511e90`, SkyLight and the live renderer removed, snapshot default again)
  committed on `main`, not pushed; all bundles green, signed build succeeded; LIVE PENDING
  (checklists 15b, 15i, row 5).
- 2026-10-15: PF-T (resource use: sampling without colour conversion, launcher icons drawn only
  when new or changed) committed on `fix/johan-spaces-safari`; all bundles green, signed build
  succeeded, measured live (Decisions and Tasks, PF-T).
