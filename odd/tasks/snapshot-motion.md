# Snapshot motion: GPU-animated window images (Niri-level fluidity)

## Objective
Scroll, maximize, resize and workspace animations look perfectly fluid at display refresh,
independent of how fast each app repaints, while real windows move only once.

## Problem (live 2026-09-29)
- AX-driven size animation: when `sizeAnimated=1` the growing app's frame cost explodes
  (Activity Monitor 251ms, dropped=26; VS Code 158ms, dropped=18) — every resize forces a full app
  relayout/redraw; the adaptive capability then disables it ("only animates the first time").
- AX-driven scroll reaches ~122 fps on Gio's side but on-screen smoothness depends on each app's
  repaint; user: "no se siente fluido como niri", "se ve raro como lag".
- Niri is a compositor: it animates window images. Gio can emulate that with ScreenCaptureKit
  snapshots in a GPU overlay; the real windows move once underneath.

## Why
User approved the snapshot overlay (2026-09-29) knowing it requires Screen Recording permission:
"la idea es que esto se vea fluido, que se sienta bien al usar".

## Design update (2026-09-29, live measurement, user accepted "si")
Measured on the user's Mac with content cached: per-window capture p50 57-147ms, max 101-179ms,
backdrop 115-139ms, total 117-183ms. On-keypress capture would delay every ~350ms animation, so:
- Pre-captured snapshot cache: after each settle (async, background, one-shot — no periodic
  timers), capture visible windows + adjacent columns' windows; at motion start use cached images
  (instant). Windows without a cached image animate via AX in that motion (fallback per window).
- Backdrop = the display's desktop wallpaper image (NSWorkspace desktopImageURL, loaded once, cached
  per display) instead of a live backdrop capture.
- Accepted tradeoff (user): during the ~350ms flight the image shows content as of the last settle;
  non-managed windows are not shown during the flight.

## Design
1. Motion start: capture every animated window (desktop-independent window capture) and a display
   backdrop EXCLUDING the animated windows (and Gio's own windows).
2. Overlay per display (borderless, click-through, above normal windows, below menus/focus ring):
   opaque backdrop layer + one CALayer per window image, animated on the GPU (Core Animation spring
   matching Niri params; resize = layer bounds/scale), retargetable from the presentation layer.
3. Real windows get ONE write to their final frame (hidden under the backdrop); overlay removed
   once layers arrive and the final exact pass settled.
4. Fallbacks: no permission / capture over budget / capture failure -> existing AX motion. Watchdog
   removes a stuck overlay. Capture timing logged every animation.

## Scope (authorized)
SM-00..SM-05. Screen Recording permission request flow included.

## Constraints
Only WindowReconciler writes managed windows; overlay is Gio-owned (own-pid guards); AppKit/CA on
main only, never blocking main or the session queue; never capture/log window titles; strict TDD for
pure parts; Conventional Commits, NO Co-Authored-By; push after verified batches, no PR.

## Tasks
- [x] SM-00 (`db4a213`) — `[animations] resize` default -> "never" (stop the laggy first adaptive attempt).
- [x] SM-01 (`d6b4160`) — Screen Recording permission: preflight/request, Overview/Diagnostics status + button,
  `[animations] renderer = "snapshot" | "ax"` (default snapshot, auto-fallback to ax when missing).
- [x] SM-02 (`a49fcad`) — Capture module: SCShareableContent window matching (pid + frame, like FI-05),
  per-window + backdrop capture in parallel, time budget, `snapshot capture ms=` log, pure matching
  and budget decisions tested.
- [x] SM-02b (`02eb486`) — Live: permission granted but first capture `captured=0 ms=50
  over-budget=8 unmatched=1` (cold, fetch inside budget). Added measure mode (2s cap, fetch/p50/p90/
  max/backdrop/unmatched reasons) + SCShareableContent prefetch outside the budget. Bundles
  25/7/19/33/920 all 0 failures (parent re-ran). LIVE PENDING: user measurement.
- [x] SM-02c (`71998d1`) — Fixes from live measurement: (a) PA-04 regression — render verification with
  `.optionOnScreenOnly` silently skips a visible target that is NOT on screen (live: focus ring on
  WhatsApp's frame, window not drawn, no `render mismatch`); a missing expected window must count
  as a mismatch and get the nudge; (b) Figma unmatched (`no-same-size-cg-entry`: AX 888 vs actual
  900 after min-size learning) — match by nearest frame within pid when unique, tolerant to learned
  minimum sizes.
- [x] SM-03 (`6cc3b76`) — Overlay renderer: per-display overlay window, backdrop + window layers, CA spring
  animations (position + bounds), retarget from presentation values, teardown.
- [x] SM-04 (`cef607d`) — Orchestration: motion start -> capture -> overlay + single real write -> settle ->
  remove overlay; rapid retargets reuse layers, newly involved windows captured on demand; focus ring
  and focus intent timing preserved; workspace switch + maximize + scroll paths.
- [x] SM-05 (`0089044`) — Safety + docs: watchdog, fallback matrix, memory limits (release images), docs.

Evidence SM-00..02 (route: one delegated writer): resize default never; renderer setting +
effectiveRenderer (snapshot only when configured + granted) + permission UI (button-only
request); SnapshotPlanning (pure: SCK->Cocoa flip, matching via CGWindowList bounds joined by
CGWindowID, exclusions, budget 45ms) + SnapshotCapturer (macOS 14+, else fallback) + Diagnostics
"Test snapshot capture". RED -> GREEN (GioMacOS parser test not run red first — noted). Bundles
25/7/19/33/914 all 0 failures (parent re-ran); signed build OK. Snapshot renderer not wired yet.
LIVE PENDING: capture latency measurement by user.

Evidence SM-02c..05 (route: one delegated writer; RED compile per task, two small tests written
with impl — noted): missing on-screen window = mismatch ws=missing, 80%-overlap matching; overlay
level normal+1 below ring/Dock/menus, CASpringAnimation (k, 2ζ√k), wallpaper backdrop; cache =
visible columns + adjacent columns + adjacent-workspace focused (<=12, 300ms after settle, LRU,
60s max age); any visible window without image -> whole motion via AX (`snapshot fallback
reason=cache-miss`); ring hidden during flight; 1.5s watchdog, mouse-down abort, display change,
revoked permission -> AX. Bundles 25/7/19/33/969 all 0 failures (parent re-ran); signed build OK.
Risks: CASpringAnimation on bounds, parked windows capture blank/stale -> fallbacks. LIVE PENDING.
- [x] SM-06 (`24b2998`) — Live bug: every snapshot flight ended after 6-83ms (spring ~350ms), so
  windows jumped; user felt it less fluid. Flight end now deadline-based (FlightDeadline from
  Gio's spring settle time, retarget extends, main timer), panel primed (orderFront + display +
  CATransaction.flush) before adding springs with explicit beginTime; warn `snapshot flight too
  short`. Root cause (CA completion on unrendered layers) unverified. Bundles 25/7/19/33/980 all 0
  failures (parent re-ran); signed build OK. LIVE PENDING.
- [x] SM-07 (`e638c5c`) — Live: flights now ~370ms but the overlay flickers on every Alt+H/J (wallpaper-file
  backdrop lacks desktop icons, focus ring hides, unmanaged windows hidden, stale images, 60ms
  fade). User chose real windows: default `renderer = "ax"`, snapshot kept as experimental
  (settings label + docs). Route: inline (mechanical, 5 files). RED: 4 default tests failed first;
  GREEN after change + pinning snapshot in 2 reason/log-gate tests. Bundles 25/7/19/33/980 all 0
  failures; signed build OK.
- [ ] SM-08 (`fa27a03`) — Overlay fidelity: one flight indistinguishable at overlay on/off, smooth under
  rapid keys (the snapshot renderer becomes the primary motion path; default stays `"ax"` until the live
  test). The SM-07 flicker causes, each with its fix:
  - Backdrop: the wallpaper file (no icons, no unmanaged windows) is gone; `WallpaperCache` and its
    notifications deleted. The flight carries the display's captured backdrop from the cache
    (`SnapshotCacheRefresher.backdrop(for:)`, SM-09) in `OverlayFlight.backdrop`; the backdrop layer draws
    it 1:1 (`contentsScale` = backing scale). `no-backdrop` only when the cache has none for an animated
    display (before the first settle refresh).
  - Ordering (prime -> writes -> fly): `drive` returns `.priming` after `beginFlight`; `performReflow`
    hands the instant pass and the AX motion for the same pass to `deferPass` and returns without
    writing. Main primes (layers at start frames, `orderFrontRegardless`, `displayIfNeeded`,
    `CATransaction.flush()`, one more main pass) and reports `snapshotPrimed(token, ok)`; the controller
    hops onto the session queue, runs the writes, then `flyFlight`. Main never waits on the session queue.
    `ok=false` -> `snapshot fallback reason=prime-failed`, overlay torn down, AX motion with nothing
    written. A pass during the prime replaces the pending closures (only the latest plan writes); a
    mouse-down/watchdog abort during the prime runs the AX fallback. The watchdog is armed at the prime,
    so a lost prime report cannot leave the panel up. `performReflow` split into `axMotionPass` and
    `instantPass` (same code, now callable later).
  - Shadows: a shadow layer per window under the image with a precomputed `shadowPath` (rounded window
    rect), `overlayWindowShadow` = offset (0, -10), radius 22, opacity 0.38: between macOS's key-window
    shadow (heavier) and the non-key one (lighter), since most tiles are not key; `shouldRasterize` off.
    Shadows sit below every image (`zPosition`), so a shadow never falls on a neighbour's image.
  - Ring and dim during the flight: the overlay draws them (`overlayDecorations`, pure, same rules as
    `focusRingState`/`focusDimRegions`; `FocusRingPublisher.flightDecorations(targets:)` at the landing
    frames): ring layer = window bounds outset by the width, `borderWidth` = width, corner radius 10 +
    width (inner edge on the window edge like the live ring); dim layer = black at `focusDimAlpha`, corner
    radius 10. `indicator = "none"` draws nothing. Live publishers stay hidden during the flight
    (`FocusDimHideReason.flight`, new) and republish at the settle BEFORE the overlay ends
    (`FocusDimPublisher.publishNow`: no 50 ms coalescing; `FocusDimController` skips the fade-in after
    `.hidden(.flight)`). Reduce Motion unchanged.
  - Retarget with velocity: `CASpringAnimation` replaced by `CAKeyframeAnimation` tracks sampled from
    Gio's own spring (`FlightTrack`, `flightKeyframes`: one sample per display refresh,
    `NSScreen.maximumFramesPerSecond`, linear between samples, `shadowPath` discrete). A retarget
    evaluates the track at the elapsed time (`FlightTrack.state`: geometry AND velocity, analytic) and
    starts a new track from there carrying the velocity (`retargeted(to:at:spring:)`). Verified: the
    analytic velocity carry in `OverlayGeometryTests` (state at t equals `SpringParameters.state` per
    axis; the retargeted track's state at t' uses the carried v0). Inferred, not verified:
    `CASpringAnimation.initialVelocity` units for point/rect values are undocumented, which is why the
    keyframe track was chosen instead of setting it; that the render server plays the keyframes at the
    display rate without visible stepping is LIVE PENDING. Deadline: `FlightTrack.settleTime` (with the
    carried velocity) at the fly; `FlightDeadline` semantics unchanged (retarget extends, never shortens;
    tests unchanged). `overlaySpring`/`retargetStart` deleted.
  - End without a pulse: the 60 ms alpha fade is gone (`endFlight()` has no fade parameter); mouse-down
    abort immediate, watchdog 1.5 s kept.
  - Fallback hygiene: every AX fallback happens before any real write (`.ax` from `drive`, `prime-failed`,
    abort during the prime); `endFlight` is called on prime failure so no panel is left.
  Route: one delegated writer (OverlayFidelity) in parallel with SM-09 (CacheFreshness), shared file
  SessionHost.swift split by region. RED observed: GioCoreTests compile failure (OverlayDecorations,
  FlightTrack, flightKeyframes, overlayWindowShadow, overlayRingGeometry, `.flight`, `.primeFailed`
  missing); GioSessionTests compile failure (`FakeOverlay` not conforming to the new `OverlayPort`,
  `flightDecorations`, `publishNow` missing). One wrong expectation fixed after GREEN (`FlightTrack.travel`
  is the edge movement, 500 not 400). GREEN: OverlayGeometryTests 17, OverlayDecorationsTests 6 (new),
  FocusDimTests 24, SnapshotFlightPlanningTests 18, SnapshotFlightTests 14 (order prime/writes/fly,
  prime failure -> AX with no write, stale prime ignored, retarget while priming supersedes the writes,
  abort while priming runs the fallback, backdrop from the cache, no-backdrop only when missing,
  decorations at begin/retarget), FocusRingPublisherTests 10, FocusDimPublisherTests 10. Full `swift test`
  (with SM-09 in the tree): GioUITests 254 (53 skipped), GioSessionTests 324, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 44, GioCoreTests 1340, all 0 failures; `git diff --check` clean. Signed build: run by the
  parent. No GioUI test for `SnapshotOverlay` (needs a window server; the UI bundle has none for panels).
  LIVE PENDING: shadow match against real windows (offset/radius/opacity by eye), hand-off invisibility
  at overlay on and off (backdrop, shadows, ring/dim in the same frame), retarget smoothness under rapid
  Alt+L, panel never stuck (watchdog from the prime), the extra main pass before `snapshotPrimed` being
  enough for the first frame, keyframe playback without stepping on 60 Hz and 120 Hz displays,
  `prime-failed` never appearing.
- [ ] SM-09 (`fa27a03`) — Cache freshness and cost (snapshot renderer becomes the primary motion path).
  Live before: `snapshot fallback reason=cache-miss ids=1..5` 60+ times (images expired after 60 s, nothing
  refreshed at rest) and every post-settle refresh re-captured the whole set (5-6 windows, ~75 ms) even
  when nothing changed. Decisions:
  - Ages: `snapshotMaxAge` 60 -> 180 s (usable), `snapshotSoftAge` 30 s (a settle re-captures older
    images), `snapshotBackdropMaxAge` 300 s. Freshness comes from dirty signals, not from a short age.
  - Selective refresh (`snapshotRefreshSelection`, pure): a run captures only missing, resized, dirty or
    soft-stale images; a window that only moved keeps its image; a settle with everything fresh captures
    nothing (`snapshot refresh skipped wanted=N fresh`). Run reason = most specific cause
    (`snapshotRefreshReason`: new > size > focus > typing > settle; backdrop-only = backdrop).
  - Dirty signals (one-shot, 0.6 s debounce, only the dirty windows, no periodic timer): typing
    (`HotkeyTap.onKeyDown` for every key-down that reaches an app; `SessionHost.noteTyping` hops to the
    session at most once per 0.5 s, `snapshotTypingHopDue`; the refresher marks the focused window), focus
    change (`publishFocusRing` -> `noteFocus`: the window that lost focus and the one that got it),
    registration (`noteRegistered` -> the placing settle captures it with `reason=new`). Size changes need
    no signal: the selection compares the cached frame with the physical one. Marks survive a run deferred
    by motion and are taken by the next settle; the ghost-only cache (ax renderer) ignores them.
  - Backdrop in the cache: per display (`SCContentFilter(display:excludingWindows:)`, excluding EVERY
    managed window — `SnapshotCaptureRequest.backdropExclusions`, matched like the captured ones — and
    every Gio-pid window), keyed by `DisplayState.frame`; `backdrop(for:)` (served whatever its age: a
    stale desktop beats an AX fallback) and `backdropAge(for:)` for the flight controller. Captured by
    the settle run when missing (first settle after start), older than 5 min, after a display change
    (`markBackdropDirty`) or when the unmanaged on-screen window set changed
    (`unmanagedWindowFingerprint` over one WindowServer query per settle run).
  - Blank guard: `snapshotSamples` (GioMacOS: a 5x5 interior grid plus five samples per edge, tiny full-cover draws, no interpolation) +
    `snapshotLooksBlank` (pure: all transparent, or every opaque sample one colour). A blank capture is a
    `blank` miss, logged once per window, and the previous image is kept. Tradeoff: a window that really
    is one flat colour (no title bar contrast) never gets an image and falls back to AX; judged rarer and
    cheaper than showing a blank layer.
  - Cost line: `snapshot capture ... pixels=P reason=<settle|typing|focus|new|size|backdrop|measure|overview>`;
    `snapshot cache entries= pixels= backdropPixels= evicted= dirty=`.
  - `SnapshotCacheRefresher.Context.capture` now completes with `SnapshotCaptureOutcome` (images +
    backdrops); `serverWindows`/`ownPid` added with defaults. Refresher tests moved to
    `SnapshotCacheRefresherTests.swift` (SnapshotFlightTests keeps the flight).
  RED (observed): SnapshotCacheTests/SnapshotPlanningTests compile failures (`snapshotSoftAge`,
  `snapshotRefreshSelection`, `snapshotLooksBlank`, `ServerWindowKey`, summary `pixels:`/`reason:`...);
  SnapshotSamplingTests compile failure (`snapshotSamples`), then one real RED
  (`testFlatColourSamplesAsBlank`: the stretched single draw gave partial-coverage edge pixels; fixed by
  full-cover draws of the image and its four one-pixel edge strips, 45 samples); SnapshotCacheRefresherTests
  written against the new behaviour before the refresher rewrite (`capture` outcome type, selection, dirty
  signals, backdrop). GREEN: SnapshotCacheTests 20, SnapshotPlanningTests 16, SnapshotSamplingTests 4,
  SnapshotCacheRefresherTests 24 (typing debounce captures only the focused window; focus change the two
  windows; new window once; fresh settle captures nothing; backdrop when missing, expired, dirty or
  unmanaged set changed; no timers at rest). Full `swift test`: GioUITests 254 (53 skipped), GioSessionTests
  324, GioPOCTests 7, GioMacTests 19, GioMacOSTests 44, GioCoreTests 1340, all 0 failures (tree includes
  SM-08). `git diff --check` clean. Signed build: run by the parent.
  LIVE PENDING: parked-window capture content (1 pt sliver, `desktopIndependentWindow`; a blank one now
  logs `snapshot window blank`), backdrop matches the desktop at overlay on/off (icons, unmanaged
  windows), fallback rate (`snapshot fallback` lines ~0 except right after a new window), per-settle
  `snapshot capture` cost (expected `windows=0..2`, not the whole set), typing/focus lines appear once
  per pause, blank-guard false positives on flat windows, an idle pause over 180 s still falls back once
  (raise `snapshotMaxAge` if that shows up in practice).
- [ ] SM-10 (`fa27a03`) — Review fixes for SM-08/SM-09 (7 findings, `agent://SnapshotReview`):
  1. (blocker) A key press during the prime was lost: the deferred writes (`instantPass` -> `motion.stop()`
     -> `reflowCoalescer.reset()`) cleared the coalesced request, the 30 ms retarget found nothing and the
     flight finished on the stale plan. `SnapshotFlightController.primed` now reads
     `takeCoalescedReflow` before the writes and, if set, puts it back (`Context.requestReflow`, new:
     `reflowCoalescer.request(motionActive: true)`) and calls `scheduleReflow()` after them.
  2. A running AX motion (after a fallback) kept ticking while main primed and its end could run the
     final pass that ends the new flight: `performReflow`'s `.priming` branch calls `motion.stop()` before
     `deferPass` (the AX fallback restarts its own motion; a stopped timer never ticks `finalPass`).
  3. Floating managed windows were cut out of the backdrop although they never fly (missing for the whole
     flight): `backdropExcludesWindow(mode:isMinimized:)` (GioCore, pure) keeps only tiled, non-minimized
     windows in `managedFrames()`; floating ones stay in the backdrop (and count in the unmanaged
     fingerprint, so dragging one re-captures it).
  4. Lazily created own panels (ring, dim) missing from the shareable-content cache were baked into the
     backdrop: before a backdrop run the capturer adds `windowServerOnScreenWindowIDs(pid: ownPid)` (one
     `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`, any layer; `parseWindowServerWindowIDs`) to
     `needed`, so `ensureCache` refetches only when one is missing.
  5. After `prime-failed` the ring stayed hidden for the whole AX motion: `primed(ok: false)` calls
     `context.publishIndicators()` right after the fallback.
  6. Wallpaper/Space changes never dirtied the captured backdrop (the deleted `WallpaperCache` observers
     were not replaced): `SessionHost.watchDesktopPicture` observes `com.apple.desktop`
     (`DistributedNotificationCenter`) and `NSWorkspace.activeSpaceDidChangeNotification`, hops to the
     session and calls `markBackdropDirty()` + `schedule()`. No timer.
  7. The blank guard rejected sparse windows (a terminal with one prompt line) and the renderer fell back
     forever on them: `snapshotLooksBlank(samples:dense:)` (pure) is blank only when the sparse samples
     look blank AND `snapshotDenseSamples` (one 64x64 nearest-neighbour draw of the whole image, ~4096
     samples, run only on a sparse blank verdict) agrees. Remaining tradeoff: content smaller than the
     dense step (a lone cursor) still reads blank.
  RED (observed): GioSessionTests compile failure (`requestReflow` missing from
  `SnapshotFlightController.Context`; tests `testACoalescedReflowSurvivesTheDeferredWrites`,
  `testNoCoalescedReflowSchedulesNothingAfterThePrime`, the `publish` event in
  `testPrimingFailureFallsBackToAXBeforeAnyWrite`); GioMacOSTests/GioCoreTests compile failures
  (`parseWindowServerWindowIDs`, `snapshotDenseSamples`, `snapshotLooksBlank(samples:dense:)`,
  `backdropExcludesWindow`; tests `testOwnWindowIDsKeepEveryLayerOfOnePid`,
  `testASparseWindowWithOnePromptLineIsNotBlank`, `testTheDenseScanRunsOnlyWhenTheSparseSamplesLookBlank`,
  `testBackdropExcludesOnlyWindowsThatCanFly`). GREEN: full `swift test`: GioUITests 254 (53 skipped),
  GioSessionTests 326, GioPOCTests 7, GioMacTests 19, GioMacOSTests 47, GioCoreTests 1341, all 0
  failures; `git diff --check` clean. Signed build: run by the parent. Fixes 2 and 6 live in
  `SessionHost` (no unit test; the stop and the observers are a few lines over tested components).
  LIVE PENDING: double press / key repeat during the prime retargets to the last press (no stale landing,
  focus on a visible window); no backwards jump after a fallback; a floating window stays visible during
  flights; no second ring/dim patches in the backdrop; the ring shows during a `prime-failed` motion;
  wallpaper change shows in the next flight; a terminal with one prompt line gets an image (no
  `snapshot window blank` for it, no `cache-miss` fallback).

- [ ] SM-11 (`fa27a03`) — Cache coverage: every workspace, two sizes, attributed misses, no endless retries.
  Live evidence (2026-10-08 18:53:49-18:55:21 UTC, debug, renderer snapshot, 189 key presses in 92 s): 53/55
  flights as images; 3 `snapshot fallback reason=cache-miss ids=1`: (1) `workspace(2)` into `5618:3` on a
  non-adjacent workspace had no image (AX motion `frames=45 dropped=42`, WhatsApp write 251 ms); (2)
  `maximizeColumn` right after the previous maximize settled: the new-size image did not exist yet (0.3 s
  debounce + ~60 ms capture), the old-size one was refused by the 2 pt rule; (3) `focusLeft` into
  `54147:10` (LoopOps refuses its width: 888 requested, 1024 actual), cause not logged. 48 captures in 92 s
  (3.7 s of capture work, 481 Mpx): 22 `reason=focus` (every Alt+H/L re-captured 2-4 windows), 26
  `reason=size` each `misses=1` (the neighbour Alt+F pushed off screen was parked, missed and was retried at
  every settle; `dirty=5..10` never drained). Misses were attributed only in measure mode.
  Decisions:
  1. Coverage: a settle run fills its 12-window budget (`maxWindows`) with the windows of every workspace of
     every stack that have no image (`coverageSet`: tiled, non-minimized, nearest workspaces first); while
     some remain the next stage runs 0.3 s after the run (`stageDelay`, one-shot; `run` refuses during
     motion/flight, the next settle resumes). Each such window is tried once (`tried`) until it registers,
     moves workspace (seen by the run, no new SessionHost call site) or shows again, so a window that cannot
     be captured never keeps stages alive; nothing is pending once covered. Dirty marks of windows that can
     no longer be captured are dropped at each run; dirty windows on hidden workspaces are captured too
     (a rule-placed new window used to stay dirty forever).
  2. Parked matching, verified with synthetic candidates: Gio stores the parking frame it wrote (1 pt
     sliver) as the physical frame; a macOS clamp moves the origin (up to 40 pt on screen) but keeps the
     size, so a unique same-pid size already matched (pass 2, `testClampedParkedWindowMatchesByItsUniqueSize`
     passed on first run: characterization). What failed was several same-size windows of one app (columns
     of one width preset): ambiguous. New rule: among same-size entries the one within clamp reach
     (`withinClampReach`, both origin deltas < `parkedStripLimit` 40 pt) matches; two within reach stay
     ambiguous. Whether ScreenCaptureKit draws a parked window's content is not provable offline: a parked
     miss (below) falls back once at most and is captured when visible.
  3. Two sizes: `SnapshotCache` keeps up to `snapshotSizesPerWindow` = 2 images per window, keyed by size
     (points, 2 pt tolerance, the latest capture of a size replaces it; a third size replaces the window's
     least recently used one). Keyed by point size instead of pixel size: one window has one backing scale
     at a time and the flight compares points. `usableEntry(id, startFrame:)`: the image of that size within
     `snapshotMaxAge`, else the newest other-size image younger than `snapshotSoftAge` flown scaled (debug
     `snapshot scaled id=P:E`), else a miss. `SnapshotCacheRefresher.hasFlightImage` (the `usable` closure in
     `drive`) / `flightImage` (makeFlights; touches the used size). The refresh selection accepts a fresh
     image of either size. Cap unchanged (12 display-fulls) but every image counts; `enforce` evicts second
     sizes before any window's newest image. `snapshot cache` line gains `images=`.
  4. Attributed misses: `SnapshotCaptureOutcome.misses` carries `SnapshotCaptureSummary.misses`; the
     refresher logs `snapshot miss id=P:E reason=<unmatched|ambiguous|over-budget|failed|blank> app=<name>`
     at debug, once per window and reason per minute (`SnapshotMissLogThrottle`); `Context.appName` added.
  5. No endless retries: a miss for any reason but `over-budget` while the requested frame is off screen
     (`snapshotFrameIsOffScreen`: under 8 pt on every display) puts the window in `parkedMisses`: no dirty
     mark, not asked for by the refresh set, coverage or a dirty run until a run sees it on screen; its
     previous image stays. (Wider than "unmatched" only: a parked window that SCK cannot draw comes back
     failed or blank, and would otherwise loop the same way.)
  6. Focus is not dirt: `noteFocus` marks nothing; it arms a one-shot 3 s check (`focusDwell`) cancelled by
     the next focus change; a window still focused then becomes dirty once with `reason=focus`.
  RED (observed): GioCoreTests compile failure (`usableEntry`, `entries(of:)`, `imageCount`,
  `touch(_:frame:at:)`, `snapshotFrameIsOffScreen`, `snapshotMissLogLine`, `SnapshotMissLogThrottle`).
  GioSessionTests: its compile RED was masked (the bundle failed first on the parallel SM-12's RED tests);
  behaviour RED observed afterwards by mutation on a scratch copy (old `noteFocus`, no coverage fill, no
  parked rule, no clamp-reach rule): `testFocusChangeAloneCapturesNothing`,
  `testWarmUpCoversEveryWorkspaceInStagesOfTwelve`, `testParkedMissIsNotRetriedUntilTheWindowIsVisible`,
  `testCoverageRetriesAMissOnlyAfterTheWindowMovesWorkspace`,
  `testClampedParkedWindowsOfOneSizeTakeTheEntryWithinClampReach` failed; restored, green.
  GREEN: SnapshotCacheTests 30, SnapshotPlanningTests 19, SnapshotCacheRefresherTests 30 (warm-up in stages of
  12 with ManualScheduler, no timers at rest, not during motion; two-size selection and scaled fallback;
  parked miss leaves `dirty` and is not retried until visible; coverage retries a miss only after a
  workspace move; focus change alone captures nothing; focused 3 s captures once; miss line format and
  throttle). Full `swift test` (tree includes SM-12 in progress): GioUITests 273 (53 skipped),
  GioSessionTests 336, GioPOCTests 7, GioMacTests 19, GioMacOSTests 48, GioCoreTests 1394, all 0 failures.
  `git diff --check` clean. Signed build: run by the parent. Also restored a stray `h` in
  `Sources/GioUI/LauncherWindow.swift` line 1 (`himport AppKit`) that broke the build (approved by the parent).
  Expected effect [INFERENCE]: in a session like the one above, captures drop from 48 (0.25 per key press)
  to the dwell captures (one per window kept focused 3 s), typing and real size changes, roughly 0.05 per
  press; no `reason=focus` per Alt+H/L; no repeated `reason=size misses=1`; `dirty` drains to 0. Fallbacks:
  (1) gone when the parked capture works (else one fallback on the first visit, with a `snapshot miss` line
  naming why); (2) gone (scaled image); (3) attributed by `snapshot miss`, and covered by a scaled image
  when one is fresh.
  LIVE PENDING: right after start a few `snapshot capture ... reason=settle` runs of up to 12 windows, then
  silence; first `workspace(N)` to a non-adjacent workspace flies (or `snapshot miss ... reason=` explains
  why parked windows cannot be captured); Alt+F twice quickly flies (`snapshot scaled` at most once);
  Alt+H/L bursts log no `reason=focus`; `snapshot cache ... dirty=0` at rest; LoopOps (`54147:*`) miss reason;
  memory with every workspace covered (`snapshot cache ... pixels=` vs the cap).

- [ ] SM-12 (`fa27a03`) — Flight latency: non-blocking real writes under the overlay, real frame
  measurement. Live evidence (user session 2026-10-08 18:53:49-18:55:21 UTC, debug, renderer snapshot, 189
  key presses in 92 s): in snapshot mode the instant pass still waited for the real writes on the session
  queue (`reflow timing total=90..158ms slowest=WhatsApp`) while the overlay already hid them, so the next
  key waited; snapshot flights logged `anim done frames=0 dropped=0` (no measure of smoothness).
  1. Non-blocking writes. `WindowReconciler.dispatch(frames:parked:focused:currentlyFocused:trusted:)`
     starts the pass on the per-app lanes and returns (`LaneExecutor.launch`; `run` is now launch + await);
     `collect(_:)` waits (bounded like `reconcile`: 0.25 s without progress = `timeout`) and folds the same
     report, timing and log lines. Decisions: no motion grace on the caller (queued motion frames of the
     pass's apps are discarded, the lane waits on its own thread up to 2 x stall for the in-flight write or
     an earlier dispatched lane, `claim(_:waitingUpTo:)` on an `NSCondition`, instead of deferring); a newer
     dispatch supersedes not-yet-started writes of the windows it writes again (latest wins; a superseded
     write is neither applied nor failed); focus runs on the focused app's lane after that lane's writes
     (never before the window is told its frame), only while it is the newest intent (`DispatchFocusBook`:
     the check and the call share one lock, issuing never waits) and is handed to a newer pass without an
     intent that writes its window again (`DispatchFocusStep.handOver`). `SessionHost.instantPass` in a
     flight merges the plans into one dispatch, records echoes and physical frames at once, invalidates the
     trust of the windows written, calls `passSettled`; `SnapshotFlightController.Context.collectWrites`
     (`collectDispatchedWrites`) folds every dispatched pass oldest first on every exit (settle before the
     ring and the overlay, abort, `end`/display change) through the same `foldSettle` as a blocking pass, so
     the render check after the settle reads back what failed. The AX renderer path is unchanged (`reconcile`
     body only refactored into `skipTrusted`/`fold`/`finish`). New debug line `reconcile dispatched
     windows=N lanes=L skippedReads=S ms=X`.
  2. Frame measurement. `FlightFrameMeter`/`FlightFrameStats`/`flightFrameStats(intervals:refreshRate:duration:)`
     (GioCore, pure; per frame one increment and one comparison). `FlightFrameLink` (GioUI) runs one
     `NSView.displayLink` (macOS 14+, nothing on 13) on the first active overlay's view from `fly` to the
     deadline (`onFlightFinished(token, stats)` -> `layersFinished(token, frames:)`); `endAll` (begin, prime
     failure, mouse-down, watchdog, end, display change) and `stop` cancel it: no link at rest.
     `anim done` for snapshot flights: `frames=<presented> dropped=<expected-presented, >=0> hitches=<n>`
     (`MotionSummary.snapshotFlight`; the AX line is unchanged); `snapshot flight ... fps=<presented/duration>`.
  RED (observed, compile failures; the shared build was blocked by SM-11's RED, so each bundle was
  type-checked against the built modules with `swiftc -typecheck`): GioCoreTests `dispatch`/`collect`
  missing on `WindowReconciler` (`WriteLaneTests` x7 new tests), `flightFrameStats`, `FlightFrameMeter`,
  `FlightFrameStats`, `MotionSummary.snapshotFlight`, `snapshotFlightLine(...frames:)`
  (`SnapshotFlightPlanningTests` x6); GioSessionTests `collectWrites` and `layersFinished(_:frames:)`
  (`SnapshotFlightTests`); GioUITests `FlightFrameLink`/`FrameLinkHandle` (`FlightFrameLinkTests`).
  First GREEN run: one failure in the RED test itself (a 0.3 s write exceeds the 0.25 s stall, so collect
  right away correctly times it out); the test now uses 0.2 s. GREEN: `WriteLaneTests` 18/18 four runs in a
  row; full `swift test`: GioUITests 273 (53 skipped), GioSessionTests 336, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 48, GioCoreTests 1394, all 0 failures; `git diff --check` clean. Signed build: run by the
  parent. Not unit-tested: the `SessionHost` dispatch/fold wiring and the `SnapshotOverlayController` link
  calls (compile-checked; the decisions are in the tested components).
  LIVE PENDING: `snapshot flight ... fps=` near the display rate (60/120) and `anim done ... renderer=snapshot`
  with low `dropped`/`hitches`; key latency with WhatsApp in the strip (rapid Alt+H/L: `reconcile dispatched
  ... ms=` well under 1 ms, no `reflow timing total=90..158ms` before the next `hotkey` line; each press
  retargets at once); after the flight every window at its final frame (no `reconcile failure ... timeout`
  for WhatsApp unless it really hung); focus lands on the last pressed target (never an older one); no
  display link left after a flight (CPU idle at rest).

- [ ] SM-13 (`fa27a03`) — Review fixes for SM-11/SM-12 (9 findings of the dual review, each cause verified
  in the code before the fix).
  0. Focus never dropped. A dispatched pass's focus step its lane never reached (claim failed after the
     claim wait, lane abandoned) runs in `WindowReconciler.collect` (`DispatchFocusStep.run`: `taken` stops a
     second run, `DispatchFocusBook.runIfLatest` keeps an older intent stale). The old blocking `reconcile`
     always focused; SM-12 only logged `focusFailed`.
  1. Claim wait is not a stall. `LaneState.awaitClaim(upTo:)` (set by `LaneExecutor.launch` when the lane
     waits for its claim): `pendingProgress` reports the claim deadline and `abandonIfStalled` skips the lane
     until `claimed()` (which now signals `await`). A lane queued behind the app's previous lane writes when
     it wins the claim, or reports `app busy` at the claim deadline; `collect` no longer abandons it after
     0.25 s. Chosen: writes (proved by the test).
  2. Echo window covers delayed landings. Verified: `WindowEventRouter.handleWindowEvent` gates moved/resized
     events only by `dropsAsMotionEcho` (the AX motion's `animatingPids`, empty during an overlay flight) and
     the echo gate, so a write landing more than 0.35 s after dispatch at a clamped frame (app minimum width)
     read as a user move (dim hold, trust and tileability invalidated, reflow). `DispatchedPass.landingBounds`
     (claim wait 2 x stall + one stall per write of the lane up to its own; 0 serial) and
     `WriteEchoGate.recordDispatched(_:frame:at:landingWithin:)` (entries now hold `suppressedUntil`);
     `SessionHost.dispatchUnderOverlay` records with the bound, and `foldSettle` now records echoes for a
     collected pass too (after its lanes returned, so at or after every landing; `recordEcho:` removed).
  3. Frame link restarts on a retarget after the deadline finished it: `FlightFrameLink.retargeted(on:...)`
     (keeps a running link, starts a new one otherwise), called by `SnapshotOverlayController.retarget`
     while flying. Before, such a flight landed with no stats (`frames=0 dropped=0`).
  4. Frame meter starts at the first display-link callback (`FlightFrameMeter`: the first callback is the
     origin, neither counted nor a hitch; a flight with no callback is measured from `start`).
     `flightFrameStats(intervals:)` takes intervals after the origin.
  5. Coverage never evicts on-screen images. `SnapshotCache.enforce(capPixels:protected:currentFrame:)`:
     images of windows outside `protected` go first (the refresher passes its refresh set: visible,
     adjacent columns, adjacent workspaces' focused), so coverage captures of hidden workspaces are evicted
     before the visible ones. Once an eviction runs, coverage stops (`snapshot coverage stopped cap reached
     images=I pixels=P`, info, once) until a window leaves the cache (`evict`, `retain` dropping one,
     `removeAll`); dirty hidden windows are still refreshed.
  6. Same-size parked windows. Chosen: the CGWindowID learned while visible (`SnapshotWindowIDBook`, GioCore,
     held by `SnapshotCapturer` under its lock). Why: Gio writes one parking frame for every same-size window
     of an app on a side and macOS clamps them alike, so no frame rule (clamp reach, AX position, list order)
     can separate them; the CGWindowID is stable for the window's lifetime and is matched without doubt
     while the window is visible (a visible frame is unique per app). Every capture run matches every
     managed window (backdrop exclusions), so the ids are learned at the first settle that shows each
     window. Pass 0 of `matchSnapshotCandidates(..., known:)` uses it; off-screen matches are never learned;
     an id its app no longer lists is forgotten. Without a learned id, pass 1 matches an exact frame only
     when it is unique both ways, so two windows at one parking frame are `ambiguous`, never swapped.
  7. One lookup per window: `SnapshotCacheRefresher.flightImage(_:startFrame:at:)` is a pure lookup at the
     controller's one `now`; `drive` memoises it per window, the plan decides with it and `makeFlights` flies
     exactly that image (`flies` marks that size used, logs `snapshot scaled`). `hasFlightImage` and the
     refresher's `touch(ids)` (touched the newest size, not the flown one) are gone.
  8. Evict the non-current size first: `enforce` marks secondary the images whose size differs from the
     window's physical frame (`currentFrame`), falling back to "not the newest" without one.
  RED (observed): 0 `testCollectRunsTheFocusOfAnAbandonedLaneExactlyOnce` (no `focus 30:1`,
  focusChanged false), `testCollectRunsTheFocusWhenTheAppStayedBusyPastTheClaimWait` (focusChanged false);
  1 `testALaneWaitingForItsClaimIsNotAbandonedAndWritesWhenItWins` (applied [], window left at its stale
  frame); 2 compile (`WriteEchoGate.recordDispatched`, `DispatchedPass.landingBounds` missing); 3 compile
  (`FlightFrameLink.retargeted` missing); 4 `testTheMeterStartsAtTheFirstDisplayCallback` (presented 13,
  expected 16, dropped 3, hitches 1, duration 0.13 instead of 12/12/0/0/0.1); 5 compile (`enforce` without
  `protected:`) and `testCoverageNeverEvictsTheVisibleImagesAndStopsAtTheCap` (visible images evicted, next
  stage scheduled, no stop line, a third capture); 6 with stub API `testSameSizeWindowsParkedAtOneFrameAreNeverGuessed`
  (id 1 -> 12, id 2 -> 11: swapped) and the learned-id tests (ambiguous, empty book); 7
  `testThePlanAndTheLayersUseTheSameImage` (layers [2:2] instead of [1:1, 2:2]: a hole in the opaque
  overlay); 8 compile (`enforce` without `currentFrame:`). `testCollectNeverRunsAnOlderFocusOverANewerOne`
  passed before and after (guard for the newest-intent rule).
  GREEN: full `swift test`: GioUITests 274 (53 skipped), GioSessionTests 338, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 48, GioCoreTests 1410, all 0 failures; `WriteLaneTests` 23/23 three more runs in a row;
  `git diff --check` clean. Signed build: run by the parent. Not unit-tested (compile-checked; the decisions
  are in tested components): `SessionHost` echo wiring, `SnapshotOverlayController.retarget` link call,
  `SnapshotCapturer` book wiring.
  LIVE PENDING: Alt+H/L toward WhatsApp during a flight: keys go to the last target (`focus intent ...
  changed=true`, never `failed=true` with no focus); after a flight no `reconcile failure ... timeout` for a
  window that only waited for its claim; no reflow or dim hold right after a flight with a clamped app
  (LoopOps); `anim done ... renderer=snapshot` with no constant `hitches=1` and no `frames=0` after a quick
  retarget; with every workspace covered, the first key after warm-up flies (no `reason=cache-miss`) and
  `snapshot coverage stopped` at most once; `workspace(N)` to a workspace of same-width columns of one app
  flies each window with its own content (no swapped images); Alt+F twice keeps the current-size image.

- [ ] SM-14 (`fa27a03`) — Blank windows after the overlay: no occlusion, hand-off only when painted.
  Report (2026-10-08, build SM-08..SM-10, renderer snapshot): "si me muevo rápido las pantallas tardan en
  renderizar y se ven espacios en blanco". Log: 505 flights, 138 lasted >= 1 s (rapid presses chain
  retargets; max 4.3 s); `render unmatched ... reason=offscreenTarget` for Xcode/WhatsApp/LoopOps.
  Known: Apple documents `NSWindow.occlusionState` (`.visible` unset when no part of the window is visible)
  and that other apps' windows occlude an app's windows (Energy Efficiency Guide, "Notify Your App When
  Visibility Changes"); Chromium's Mac occlusion design tells an occluded window's renderer it is hidden,
  and a hidden renderer stops producing frames. Inferred (no Apple doc states it): the WindowServer computes
  occlusion from opaque windows, so the old display-sized `isOpaque = true` panel at `.normal + 1` occluded
  every window under it for the whole flight (1-4 s with rapid presses); the windows written to their
  final frames at flight start (many from parking frames, also unpainted there) had not repainted when the
  panel dropped.
  1. No occlusion. `SnapshotOverlay`: `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`;
     the picture stays opaque (root layer black fill, display-sized backdrop layer). Level, collection
     behavior, `ignoresMouseEvents` unchanged. No other opaque/fade assumption found (the priming flush
     does not depend on it; comments in `SnapshotFlightController`, `SnapshotFlightPlanning`, `SessionHost`
     now say "draws an opaque picture").
  2. Hand-off only when painted. Pure (`GioCore/Snapshot/SnapshotHandoff.swift`):
     `snapshotPaintCheckWindows` (visible at the target on a covered display, and not fully inside a
     screen at the flight start, no known start, or resized; static or moved same-size visible windows
     excluded), `snapshotPaintCheckPixelSize` (96 px wide, aspect kept), `SnapshotHandoff` (begin/check,
     re-check only the unpainted ones every 30 ms, release when none reads blank or at the 300 ms cap, a
     window the capture cannot see is `unknown` and does not hold, tokens: `cancel` makes late answers and
     the cap no-ops), `SnapshotHandoffSummary` (`snapshot handoff waited ms=N windows=N painted=N`, info
     when a window read blank at a check or the cap was reached, debug otherwise). Session
     (`SnapshotFlightController`): the flight-start frame of each window (when it joined the flight) and
     its latest target are kept; at the settle the writes are folded, then the hold runs; `isActive`
     covers the hold (ring/dim hidden, cache refresh and render checks wait); a key press during the hold
     cancels it and retargets as in the air; `aborted` (mouse down, watchdog) and `end` cancel it; the
     ring/dim publish, `endFlight`, render check and cache refresh run at the release. The check
     (`Context.checkPaint` -> `SnapshotCapturer.paintCheck`, `Task.detached`, answer hops back) never
     blocks the session queue; main only removes the panel. Cheaper signal: none found (the WindowServer
     list has bounds/layer/on-screen, not paint state; AX has none), so the SCK capture + SM-10 blank test
     with the dense scan is used.
  3. Watchdog: `FlightWatchdog.arm(at:limit:)`; the overlay re-arms it at the deadline with
     `SnapshotHandoff.watchdogLimit` (cap 0.3 s + margin 0.2 s) instead of disarming, so a lost hand-off
     still ends the panel (`reason=watchdog`).
  Limit: the blank test only catches a window that is uniformly blank; stale content or a partly white
  window passes.
  RED (observed, compile): `OverlayGeometryTests.swift:206 extra argument 'limit' in call` (first build;
  it stopped at that file), then `SnapshotFlightTests.swift: extra argument 'checkPaint' in call`, `cannot
  find type 'SnapshotPaintVerdict'`, `cannot find 'SnapshotHandoff'` (10 errors). The SnapshotHandoffTests
  errors were not printed (the build stopped before that file); the file references only the new API.
  GREEN: targeted `SnapshotHandoffTests` 17/17, `OverlayGeometryTests` 18/18, `SnapshotFlightTests` 27/27;
  full `swift test`: GioUITests 274 (53 skipped), GioSessionTests 344, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 48, GioCoreTests 1433, all 0 failures; `git diff --check` clean. Signed build: run by the
  parent. Not unit-tested (compile-checked): `SnapshotOverlay` panel opacity and watchdog re-arm,
  `SnapshotCapturer.paintCheck`, `SessionHost` wiring.
  LIVE PENDING: whether Chromium/Electron (Chrome, Code, Slack) keep painting under the non-opaque overlay
  (no blank areas after rapid `Alt+L`/`Alt+H` and `Alt+U`/`Alt+I`); how often `snapshot handoff waited`
  logs at info and its `ms`; `ms=300` with `painted` < `windows` on every flight would mean an app still
  does not paint behind the overlay; no `snapshot flight aborted reason=watchdog` from the hold.

- [ ] SM-16 (`fa27a03`) — Windows without an image show through holes in the backdrop.
  Live (2026-10-08 20:28-20:31 UTC, renderer snapshot, debug): flights smooth (`fps=114..120`), but "aún
  está el bug en el que tarda en mostrar algunas ventanas y se ve como un espacio vacío hasta que
  aparecen". Rapid Alt+H/L chains logged `snapshot retarget uncovered ids=1..3` (10x) and 7 `snapshot
  fallback reason=cache-miss`; the images were missing because same-app, same-size windows parked at the
  same frame are ambiguous (`snapshot miss ... reason=ambiguous`, SM-17). An uncovered window was written
  once to its final frame and revealed only when the overlay ended; meanwhile the backdrop (which excludes
  every managed window) showed empty desktop there. All-or-nothing at the start turned every such motion
  into an AX motion of unpainted parked Chromium windows.
  1. Holes. Pure `snapshotHoles(layered:targets:displays:activeDisplays:)` (`SnapshotFlightPlanning`):
     every window without a layer visible at its target (`overlayDisplayIndex` of the target, the 8 pt
     rule: parked windows and their sliver excluded) on an overlaid display. Pure
     `overlayBackdropHoles`/`overlayBackdropMask` (`OverlayGeometry`): hole rects in overlay-local space
     (both flips), mask path = display rect + the hole rects rounded like the window layers
     (`overlayWindowCornerRadius`, clamped), merged with `CGPath.union` so overlapping holes stay open,
     filled even-odd; nil without a hole on that display. `SnapshotOverlay`: the black fill moved from
     the root layer (now clear) to the backdrop layer; the backdrop gets a `CAShapeLayer` mask (even-odd)
     at begin and on retarget only, removed at `end`; image layers still draw above it.
  2. No all-or-nothing. `planSnapshotFlight` returns `.snapshot(items:holes:)`: items = involved windows
     with an image, holes as above; `fallback(reason: .cacheMiss)` only when no moving window has an image
     (`missing` = the involved windows without one), `noBackdrop` as before; `finalFrames` includes holes.
     A window without an image leaving for its parking frame has no hole (it disappears at the start).
     Every display with items or holes gets a flight. Debug `snapshot holes ids=N` at begin when there are
     holes, and on a retarget when the set changed.
  3. Retarget and hand-off. `SnapshotFlightController` keeps the hole set (target frames) and recomputes it
     on every retarget from the merged latest targets and the layered ids (uncovered windows gain a hole, a
     window that got a layer or went parked loses it); `OverlayPort.beginFlight`/`retargetFlight` carry it
     (`SessionHost` hooks `overlayBegin`/`overlayRetarget` gained `[CGRect]`, `main.swift` forwards to
     `SnapshotOverlayController.begin/retarget(holes:)`). The SM-14 paint-check set is
     `snapshotPaintCheckWindows(...) ∪ holes`.
  RED (observed, compile): `OverlayGeometryTests.swift:45 cannot find 'overlayBackdropHoles' in scope`,
  `cannot find 'overlayBackdropMask' in scope` (the build stopped at that file; the planning and session
  tests reference only the new `SnapshotHole`, `snapshotHoles`, `snapshotHolesLine`, `.snapshot(items:holes:)`
  and the `holes:` port arguments). Re-pinned: `testAMissingImageOfAnyVisibleWindowFallsBackToAX...` ->
  `testAVisibleWindowWithoutAnImageIsAHoleAtItsTarget` + `testWithoutAnImageOfAnyMovingWindowTheMotionFallsBackToAX`;
  `testAWindowScrollingInFromParkedNeedsAnImage` -> `...WithoutAnImageIsAHole`; session
  `testCacheMissFallsBackAndRefreshesSoon` now has only the static window's image.
  GREEN: targeted `SnapshotFlightPlanningTests`, `OverlayGeometryTests`, `SnapshotFlightTests`,
  `SnapshotHandoffTests` 0 failures; full `swift test`: GioUITests 274 (53 skipped), GioSessionTests 348,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 49, GioCoreTests 1449, all 0 failures; `git diff --check`
  clean. Signed build: run by the parent. Not unit-tested (compile-checked): the `CAShapeLayer` mask, the
  clear root layer, `SessionHost`/`main.swift` wiring.
  LIVE PENDING: the hole looks right (real window at its landing frame, rounded corners, neighbours'
  images sliding over it, no black or empty rectangle); Chromium/Electron windows paint under the
  non-occluding panel inside the hole (no white or stale area); no `snapshot fallback reason=cache-miss`
  during rapid Alt+H/L chains unless no moving window has an image.

- [ ] SM-17 (`fa27a03`) — Title tie-break for same-size parked windows never seen on screen.
  Evidence (2026-10-08 20:28-20:31 UTC, renderer snapshot, debug): `snapshot miss id=5618:3/5618:4
  reason=ambiguous app=Google Chrome`, `5980:5/6/7 reason=ambiguous app=Code`: same-app, same-size windows
  parked at one parking frame; SM-13 learns CGWindowIDs only while a window is visible, so windows not seen
  since launch stayed ambiguous, got no image (7 `snapshot fallback reason=cache-miss` in one Alt+L chain;
  with SM-16 they are holes showing the window late).
  1. Candidates carry the listed window name: `parseSnapshotCandidates` reads `kCGWindowName` (present only
     with Screen Recording, which the capture needs anyway) into `SnapshotCandidate.title` (empty -> nil).
     `SnapshotCandidate`'s `description`/`debugDescription`/`customMirror` leave the title out (only
     `titled: <bool>`), so an interpolated candidate or a failure message never carries it.
  2. Pure decision `snapshotTitleTieBreaks(managed:candidates:matches:titles:)` (GioCore `SnapshotPlanning`):
     for each `ambiguous` window with a non-empty title, the pool is the same-pid, same-size candidates no
     window holds, narrowed to the clamp reach of its frame when any is there; exactly one pool candidate
     named like the title, and no other ambiguous same-pid same-size window with that title -> matched.
     Equal titles, a missing title on either side, other pid/size, or a name only outside the clamp reach
     stay ambiguous; an entry held by another window is never taken (never swapped).
  3. Capturer (`SnapshotCapturer.match`, used by capture runs and the SM-14 paint check): frames first
     (learned ids, passes 1-3, under the lock); then, only for ambiguous windows of apps that list names,
     the AX titles through `setWindowTitleReader` (set by `SessionHost.initialSync` from the actuator's
     registered element, `axTitle(of:)`; read on the capture task, outside the lock, never on the session
     queue), compared and dropped on return. Debug `snapshot match tie-break id=P:E by=title` per window.
     `SnapshotWindowIDBook.learn(..., identified:)` learns tie-broken matches wherever the window is, so
     later passes are title-free (the paint check learns only those, as before it learned nothing).
  4. Startup coverage (SM-11) unchanged: with the parked windows matched it asks for each once; a parked
     window that captures blank keeps no image and is not retried until it shows (guard test); during a
     flight the SM-16 hole covers it.
  RED (observed, compile): GioMacOSTests `WindowServerSnapshotTests.swift:65/66 value of type
  'SnapshotCandidate' has no member 'title'`; GioCoreTests (`swift build --target GioCoreTests`): `extra
  argument 'title' in call`, `cannot find 'snapshotTitleTieBreaks' in scope`, `extra argument 'identified'
  in call`, `cannot find 'snapshotTieBreakLogLine' in scope`. The refresher guard
  `testStartupCoverageAsksEveryParkedWindowOnceAndDropsABlankOne` exercises unchanged refresher code (no
  RED expected; green on first run).
  GREEN: targeted `SnapshotPlanningTests` 29, `WindowServerSnapshotTests` 5, `SnapshotCacheRefresherTests`
  32, 0 failures; full `swift test`: GioUITests 274 (53 skipped), GioSessionTests 348, GioPOCTests 7,
  GioMacTests 19, GioMacOSTests 49, GioCoreTests 1449, all 0 failures; `git diff --check` clean. Signed
  build: run by the parent. Not unit-tested (compile-checked): `SnapshotCapturer` title reads and tie-break
  wiring, `SessionHost` reader.
  LIVE PENDING: after launch with several same-size Chrome/Code windows parked, `snapshot match tie-break
  ... by=title` once per such window and `snapshot miss reason=ambiguous` about 0 (left only for equal or
  empty titles, e.g. two "New Tab" windows); every parked window captured at startup (coverage); no
  swapped images in a flight; no title in any log line.

- [ ] SM-18 (`fa27a03`) — The overlay panel stops at the usable frame (menu bar and Dock stay live).
  Evidence (2026-10-08, user screenshot during a flight): the menu bar showed a stale app name and clock
  ("Tern", 1:44 pm). The panel covered the whole display and its backdrop (a display capture) contains the
  menu bar; the live menu bar is transparent and draws above level `.normal + 1`, so the captured one showed
  through. Same for a visible Dock (translucent, level 20).
  1. Pure `OverlayArea(display:usable:)` (GioCore `OverlayGeometry`): `panelFrame` = the usable frame clamped
     to the display (the whole display when they do not overlap; auto-hide menu bar/Dock: equal, unchanged
     behaviour). `backdropContentsRect(scale:flipped:)`: the unit rect of the display capture under the panel,
     edges snapped to the capture's pixel grid; `flipped` = unit y from the top. Layer geometry, holes and
     the backdrop mask use the existing `overlayLayerGeometry`/`overlayBackdropHoles`/`overlayBackdropMask`
     with `in: panelFrame`; ring, dim and shadow derive from the window layer geometry, so they follow.
  2. Wiring: `SnapshotFlightController.Context.usableFrames` (index-aligned with `displayFrames`;
     `SessionHost`: `visibleFrames[id] ?? frame`, the layout's frames) -> `OverlayFlight.usableFrame` ->
     `SnapshotDisplayFlight.usableFrame` (`HostOverlayPort`) -> `SnapshotOverlay.begin(usable:...)`, which
     sets the panel frame, the root/backdrop bounds and `backdrop.contentsRect` (scale = capture pixels per
     point, `flipped` = `backdrop.contentsAreFlipped()`; no re-capture). Retargets reuse the frame set at
     begin. A usable-frame change (Dock moved, menu bar auto-hide toggled) posts the screen-parameters
     notification: the existing display-change abort ends the flight, `syncDisplays` stores the new
     `visibleFrame`, the next flight uses it. Close ghost unchanged.
  RED (observed, compile, `swift build --build-tests`): GioCoreTests `OverlayAreaTests.swift`: `cannot find
  'OverlayArea' in scope`. The GioSessionTests RED (`usableFrames:` argument, `usableFrame` member; new
  `testEachFlightCarriesItsDisplaysUsableFrame`, full-frame assertion in `testTheBackdropComesFromTheCache`)
  was written in the same step and not shown separately: the build stopped at GioCoreTests first.
  GREEN: full `swift test`: GioUITests 274 (53 skipped), GioSessionTests 349, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 49, GioCoreTests 1460, all 0 failures; `git diff --check` clean. Signed build: run by the
  parent. Not unit-tested (compile-checked): `SnapshotOverlay` panel frame and `contentsRect` assignment,
  `SessionHost` closure.
  LIVE PENDING: during flights the menu bar keeps the current app and clock and a visible Dock stays live;
  the backdrop lines up with the desktop around it (no vertical shift by the menu bar or Dock height: this
  also confirms the inferred macOS `contentsRect` y origin, bottom-left for unflipped contents); repeat with
  the Dock on the left and with auto-hide; move the Dock between flights.

- [ ] SM-19 (`fa27a03`) — Early paint check and trusted apps: the hand-off stops waiting for the check.
  Evidence (2026-10-08 21:04-21:08 UTC, 229 s, 519 presses, renderer snapshot, debug): 146 paint checks,
  0 blank; every hand-off held the overlay ~56 ms after the deadline (median 56, max 76), the time of the
  check itself; the checks cost 8.0 s of ScreenCaptureKit time vs 5.0 s for all cache captures.
  1. Pure `SnapshotHandoff` (GioCore): `earlyLead` 80 ms, `earlyCheckTime(deadline:now:)` (at once for a
     shorter flight), `prepare(windows:)` = the early check (`.check`, nothing held, its answer stored by
     `record`); `begin` at the settle releases at once (`waited ms=0`) when every window read painted or
     unseen, checks the blank ones again at once and holds as before (30 ms re-checks, 300 ms cap), returns
     `.awaiting` while the early check is still out (its answer continues the hold), and drops the early
     answer when the set grew. `cancel` (retarget, abort, end) drops a pending early check.
  2. Pure `PaintTrustBook` (session lifetime, per pid): 5 consecutive checks with a painted window and no
     blank one trust the app (`windowsToCheck` drops its windows); a blank for any of its windows resets the
     run; hole windows (SM-16) always stay; an all-`unknown` check counts for nothing.
  3. Wiring: `SnapshotOverlayController.onDeadlineArmed` (each `scheduleDeadline`: fly, retarget while
     flying) -> `main.swift` -> `SessionHost.snapshotDeadlineArmed` -> `SnapshotFlightController.deadlineArmed`
     (hops on; current gate token only) -> one `asyncAfter` to the early time that re-checks the token and
     `gate.isActive`, then `prepare(paintCheckWindows())`. Answers of the current token feed `PaintTrustBook`.
     No timer at rest: one one-shot per armed deadline; a retarget supersedes the token so it no-ops.
     Log line format unchanged.
  RED (observed, compile, `swift build --build-tests`): GioSessionTests `SnapshotFlightTests.swift`: `value of
  type 'SnapshotFlightController' has no member 'deadlineArmed'`, `type 'SnapshotHandoff' has no member
  'earlyLead'`, `cannot find 'PaintTrustBook' in scope`. The GioCoreTests RED (`SnapshotHandoffTests`: early
  time, release at the deadline when painted, hold on an early blank, early check awaited, uncovered window
  re-checked, retarget cancels and re-prepares, nothing to prepare, trust after 5, blank resets, unknown is no
  evidence, holes always checked) was written in the same step and not shown separately.
  GREEN: targeted `SnapshotHandoffTests` 28, `SnapshotFlightTests` 36 (5 new: no hold when the early check read
  painted, early blank holds, retarget cancels and re-schedules, stale deadline report, trusted app not checked).
  Full `swift test`: GioUITests 274 (53 skipped), GioSessionTests 354, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 49, GioCoreTests 1480, all 0 failures; `git diff --check` clean. Signed build: run by the
  parent. Not unit-tested (compile-checked): `SnapshotOverlayController.onDeadlineArmed`, `main.swift` and
  `SessionHost` forwarding.
  Expected effect (not measured): `snapshot handoff waited ms=0` for most flights (vs median 56 ms), paint
  checks drop to about 5 per app per session plus hole windows and apps that read blank (vs 146 in 229 s).
  LIVE PENDING: `waited ms=0` dominates; `windows=0` after a few flights per app; no blank windows after the
  overlay; ScreenCaptureKit time of the checks far below the cache captures.

- [ ] SM-20 (`fa27a03`) — Cache diet: prune unusable images, memory pressure, cap 8, stacking-order tie-break.
  Evidence (same session as SM-19): `snapshot cache entries=12 images=14 pixels=68346128
  backdropPixels=8416800` ≈ 307 MB (BGRA); images older than `snapshotMaxAge` (180 s) never fly but stayed
  until the 12-display cap evicted them; nothing reacted to memory pressure. `snapshot miss id=5618:3/5618:4
  reason=ambiguous app=Google Chrome` persisted after SM-17 (equal titles, likely two "New Tab"), so both flew
  as holes (SM-16).
  1. Prune (pure `SnapshotCache.prune`, `SnapshotPruneResult`, `SnapshotPruneReason`): every settle run of
     `SnapshotCacheRefresher` first drops an image of the window's current size (physical frame) older than
     the max age, one of another size older than `snapshotSoftAge` (it only flies scaled within it), any image
     older than the max age of a window without a frame, and backdrops of displays that are gone (moved from
     the silent `retainBackdrops` in `backdropFrames`). Kept = exactly what `usableEntry` can return from the
     current frame (flights always pass a start frame). Debug `snapshot cache pruned images=N
     reason=<age|size|display>`. Pruned windows stay `tried`: coverage never re-asks them in a loop; a window
     emptied by the prune clears `coverageStopped` like any window leaving the cache. Coverage re-asks hidden
     windows only when never tried, moved workspace (SM-11), or (new) their workspace enters the set of shown
     workspaces and their stack neighbours (`nearWorkspaces`). The refresh set (visible, next columns,
     adjacent workspaces' focused windows) keeps its freshness rules (missing -> captured). Trade-off: an
     Alt+F size image past 30 s is dropped; toggling back without a settle in between flies that window as a
     hole (SM-16) until the next settle captures it (`sizeChanged`).
  2. Memory pressure: `SessionHost.watchMemoryPressure` (`DispatchSource.makeMemoryPressureSource(eventMask:
     [.warning, .critical])` on the session queue, no timer, cancelled in `shutdown`) ->
     `SnapshotCacheRefresher.noteMemoryPressure(event)` -> pure `SnapshotCache.relieve`: warning keeps only the
     refresh set's images (all sizes), critical only the visible windows' current-size images; both keep the
     shown displays' backdrops and drop others; `.normal` does nothing. Info `snapshot cache pressure
     level=<warning|critical> freed=N` (images). Dropped hidden windows stay `tried`. Not handled: a critical
     state that persists after the event still lets the next settle re-capture the refresh set (the source
     reports transitions only).
  3. Cap 12 -> 8 display-fulls, backdrops counted (`enforce` adds `backdropPixels` to the total, never evicts
     them). Justification: `testTheVisibleAndAdjacentSetOfAThreeWorkspaceSetupFitsUnderTheCap` (shown workspace
     in the middle of three, every window display-size: visible column, both neighbour columns, both adjacent
     focused windows = 5 images + backdrop ≈ 6 display-fulls, `evicted=0`, 2 display-fulls of room for
     coverage). The visible+adjacent set never exceeds 8 for that setup, so 8 stands.
  4. Stacking-order tie-break (pure `snapshotOrderTieBreaks`, `SnapshotTieBreak`): after the title tie-break,
     still-ambiguous windows are grouped by pid and size; the pool is the same-pid, same-size candidates no
     window holds. Only when group and pool have exactly the same count, every window appears once in the
     app's AX order and every pool entry in the on-screen stacking, they match rank to rank; anything else
     stays ambiguous (never a guess, never a held entry). Capturer: `SnapshotCapturer.setWindowOrderReader`
     (set by `SessionHost.initialSync`: `axWindowOrder(pid:identify:)` reads `kAXWindowsAttribute` of
     `AXUIElementCreateApplication(pid)` with the 0.25 s messaging timeout, never Gio's pid, mapped through
     `AXWindowActuator.id(matching:pid:)`; no titles) is called on the capture task only for pids with
     ambiguous windows; the stacking is `windowServerStacking(pids:)` (`optionOnScreenOnly`, layer 0; parked
     windows keep a sliver on screen). Debug `snapshot match tie-break id=P:E by=order` (the SM-17 line is now
     `snapshotTieBreakLogLine(_:by:)`, `by=title`). Order matches are never learned by `SnapshotWindowIDBook`:
     a learned id beats the frame (pass 0), so a wrong rank would outlive the window showing; they are derived
     again each run and a visible window is matched and learned by its frame.
     Documented: CGWindow.h, `kCGWindowListOptionOnScreenOnly`: "List all on-screen windows in this user
     session, ordered from front to back"; `kCGWindowListOptionAll` (the candidate list) states no order, which
     is why the stacking comes from the on-screen list. `kAXWindowsAttribute`: "An array of accessibility
     objects representing this application's windows" (no order stated). Inferred, not documented: AppKit apps
     (Chrome included) list AX windows front to back, matching the WindowServer order; if an app does not, its
     tied windows would show each other's image in a flight (LIVE PENDING checks it).
  RED (observed, compile): GioMacOSTests `WindowServerSnapshotTests.swift:81 cannot find
  'parseWindowServerStacking' in scope` (stopped `swift build --build-tests`); `swift build --target
  GioCoreTests`: `value of type 'SnapshotCache<String>' has no member 'prune'`, `... no member 'relieve'`,
  `cannot find 'snapshotPressureLogLine' in scope`, `cannot find 'snapshotOrderTieBreaks' in scope`, `extra
  argument 'by' in call`; `swift build --target GioSessionTests`: `value of type 'SnapshotCacheRefresher' has no
  member 'noteMemoryPressure'`. Re-pinned: `testCapIsTwelveDisplaysOfPixels` -> `testCapIsEightDisplaysOfPixels`;
  `testCoverageNeverEvictsTheVisibleImagesAndStopsAtTheCap` asserts `pixels + backdropPixels <= 1584` (was
  windows only, 2376). The cap guard test passes under either cap by design (it is the evidence for 8).
  GREEN: targeted `SnapshotCacheTests` 38, `SnapshotPlanningTests` 33, `SnapshotCacheRefresherTests` 39 (7 new:
  prune without a loop, re-capture when the workspace becomes adjacent, gone display backdrop, warning,
  critical, normal event, cap fit), `WindowServerSnapshotTests` 6, 0 failures. Full `swift test`: GioUITests
  274 (53 skipped), GioSessionTests 361, GioPOCTests 7, GioMacTests 19, GioMacOSTests 50, GioCoreTests 1489, all
  0 failures (with SM-19 in the tree); `git diff --check` clean. Signed build: run by the parent. Not
  unit-tested (compile-checked): `axWindowOrder`, `windowServerStacking`, the capturer's order wiring,
  `SessionHost` reader and memory-pressure source.
  Expected effect [INFERENCE] for the user's setup (12 windows, 4-5 workspaces, one 1800x1169 pt @2x display:
  one display-full = 8,416,800 px = 33.7 MB; the live images averaged 4.88 M px = 0.58 display): peak bounded
  by the cap, 67,334,400 px ≈ 269 MB including the backdrop (the live 76.8 M px / 307 MB set no longer fits;
  coverage evicts hidden images first). At rest, 3 minutes after the last far switch, only the refresh set
  survives: about 4-5 images (shown workspace's 2-3 windows plus 2 adjacent focused) ≈ 22-25 M px plus the
  backdrop ≈ 30-33 M px ≈ 120-135 MB. Under a warning event: the same; under critical: the 1-3 visible
  windows plus the backdrop ≈ 15-25 M px ≈ 60-100 MB.
  LIVE PENDING: `snapshot cache ... pixels=P backdropPixels=B` with P+B <= 67,334,400 always and near the
  refresh set's size a few minutes after the last far switch; `snapshot cache pruned ... reason=age` without
  repeated `snapshot capture` of the pruned hidden windows; `snapshot match tie-break ... by=order` for the
  same-title Chrome windows and `reason=ambiguous` ≈ 0; no swapped images in a flight; no new `snapshot
  fallback` compared with the SM-19 session.

- [ ] SM-21 (`fa27a03`) — The shown strip survives memory pressure and the cap; warning is not a purge.
  Evidence (live 2026-10-08 21:41:14-21:42:46 UTC, SM-20 build): flights better than ever (fps median 119,
  min 114; single flights with a hitch 17 %, was 50 %; hand-off wait 0 ms), yet the user: "antes se sentía un
  poco más fluido". At 21:41:47 `snapshot cache pressure level=warning freed=7` (24 GB Mac, `memory_pressure`
  44 % free: a system-wide warning, not scarcity for Gio). Before it 16 flights, 0 holes; after it 34 flights,
  43 `snapshot holes ids=1..3` (windows without an image fly as static holes: the real window revealed instead
  of sliding). The post-settle refresh logged `snapshot refresh skipped wanted=4..6 fresh` and captured only
  1-5 windows: the dropped windows (strip columns beyond the visible + neighbour set, adjacent-workspace
  windows) were never re-captured because SM-20 kept pruned/relieved windows `tried`. Cache before the purge:
  12 images, 56 Mpx + 8.4 Mpx backdrop (~260 MB). Supersedes SM-20 item 2 (warning/critical sets) and the
  "pruned windows stay tried" rule for windows of shown workspaces.
  1. Warning is not a purge (pure `SnapshotCache.relieve(_:shown:adjacent:currentFrame:displayFrames:now:)`):
     windows of the shown workspaces (`shown`, the strips) and of their stack neighbours (`adjacent`) keep
     every image; other windows lose only images no flight can use (past `snapshotMaxAge`) or would use second
     (another size than the current one). Critical keeps the shown strips' current-size images and nothing
     else. Both keep shown displays' backdrops. Info line unchanged (`level=<warning|critical> freed=N`).
  2. Strip coverage (pure `snapshotStripSelection`; `SnapshotCacheRefresher.stripPlan`): every tiled,
     non-minimized window of every shown workspace (all columns) without a usable current-size image (none,
     only another size, past the max age; or dirty) is selected by the settle run after the refresh set,
     whether tried or not; parked misses (blank/unmatchable parked windows, SM-11/SM-17) excluded. Staged
     (12 per run, one-shot 0.3 s stage while a strip window lacking an image was not asked for since the last
     settle, `stripPass`, reset by `schedule()`); a stage never asks one window twice, so a window that keeps
     missing waits for the next settle (no stage loop); never during motion/flight (the run guard), no
     periodic timer. Adjacent/hidden workspaces unchanged (SM-11/SM-20: focused windows + coverage, re-asked
     when the workspace becomes adjacent).
  3. Recovery: `SessionHost.watchMemoryPressure` now listens to `[.normal, .warning, .critical]`; normal after
     a warning or critical logs info `snapshot cache pressure level=normal` and calls `schedule()` (one run,
     new strip pass); normal without a prior event does nothing. Besides, every settle re-checks the strip.
  4. Cap protects the strip: `enforce(capPixels:protected:pinned:currentFrame:)` never evicts a `pinned`
     window's primary image (its current size; the newest without a frame); its other sizes and every other
     window still go (pinned counts as protected for the order). When the strip alone exceeds the cap it
     yields: debug `snapshot cache cap exceeded by strip images=N` (`snapshotStripCapLogLine`) once until the
     cache fits again. Cap stays 8 display-fulls.
  5. Re-pinned/deleted SM-20 tests: Core `testWarningPressureKeepsOnlyTheVisibleAndAdjacentWindows` ->
     `testWarningPressureDropsOnlyUnusableOrSecondaryImagesAwayFromTheShownWorkspaces`,
     `testCriticalPressureKeepsOnlyTheVisibleCurrentSizeAndShownBackdrops` ->
     `testCriticalPressureKeepsTheShownStripAtCurrentSizeAndShownBackdrops`; Session
     `testMemoryPressureWarningKeepsTheVisibleAndAdjacentImages` ->
     `testMemoryPressureWarningDropsNoImageOfTheShownOrAdjacentWorkspaces`,
     `testMemoryPressureCriticalKeepsOnlyTheVisibleCurrentSizeImagesAndTheBackdrop` ->
     `testMemoryPressureCriticalKeepsTheShownStripAtCurrentSizeAndTheBackdrop`, `testANormalMemoryEventChangesNothing`
     -> `testANormalMemoryEventWithoutPressureChangesNothing`. Kept: the hidden-workspace "pruned stays tried"
     tests (`testSettlePrunesWhatNoFlightCanUseAndNeverRecapturesItInALoop`, adjacent re-capture).
  RED (observed): `swift build --build-tests` with the Core change held back: `SnapshotCacheTests.swift:405
  extra arguments at positions #2, #6 in call` / `missing argument for parameter 'visible'` (relieve), `:450
  cannot find 'snapshotStripSelection' in scope`, `cannot find 'snapshotStripCapLogLine' in scope`, enforce
  `pinned`. Session tests with the new Core and the SM-20 refresher (call site only adapted): `testMemoryPressureCriticalKeepsTheShownStripAtCurrentSizeAndTheBackdrop`
  (ids [idA, idB] only, freed line), `testPrunedStripWindowsBeyondTheNeighbourColumnAreCapturedAgainAlthoughTried`
  (request [idA, idB, strip0] instead of the whole strip), `testAStripWindowThatKeepsMissingIsNotRetriedInAStageLoop`,
  `testAfterACriticalReliefTheNextSettleRecapturesTheStripInStages` (1 window instead of 12, no stage),
  `testPressureBackToNormalRecapturesWhatTheStripLacks` (no normal line, 0 pending), `testTheCapYieldsToTheStripAndLogsItOnce`
  (total 1400, strip images evicted, no log) failed; the warning session test passed already on the new Core
  (its RED is the Core one).
  GREEN: `SnapshotCacheTests` 40, `SnapshotCacheRefresherTests` 44, `SnapshotFlightTests` 36, 0 failures. Full
  `swift test`: GioUITests 274 (53 skipped), GioSessionTests 366, GioPOCTests 7, GioMacTests 19, GioMacOSTests
  50, GioCoreTests 1491, all 0 failures; `git diff --check` clean. Signed build: run by the parent. Not
  unit-tested (compile-checked): `SessionHost.watchMemoryPressure` mask.
  Trade-off [INFERENCE]: the strip is never trimmed by the cap or a warning, so a shown workspace with many
  display-size windows can hold more than 8 display-fulls (logged); a strip window parked past 180 s is
  re-captured at the next settle (prune, then strip coverage), a few parked captures per settle at most.
  LIVE PENDING: `snapshot holes` ≈ 0 except for windows never seen (brand-new, parked blank); after a
  `snapshot cache pressure level=warning freed=N` line, N small and the next flights without holes (strip
  intact); after `level=critical`/`level=normal`, the next settle's `snapshot capture ... reason=settle` covers
  the shown strip (staged by 12) and holes stay ≈ 0; `snapshot cache cap exceeded by strip` rare.

- [x] SM-22 (`fdca808`) — Hidden workspaces at half resolution; cap tied to physical RAM.
  Evidence (live 2026-10-08 21:57-21:59 UTC): 79/80 flights as images but 8 holes after `snapshot coverage
  stopped cap reached images=12 pixels=56439696`: on the user's 1800 x 1169 pt @2x display the cap (8
  display-fulls, 67,334,400 px, ~270 MB) could not hold the windows of hidden workspaces at full resolution, so
  workspace switches showed static holes. Raising the cap was rejected for 8 GB Macs (user approved 2026-10-08).
  1. Resolution per window (pure `SnapshotResolution`, `snapshotCaptureResolution(_:shown:)`): the shown strips
     (`stripPlan`) at the backing scale, every other window (adjacent focused windows, coverage) at half of it,
     a quarter of the pixels. `SnapshotCacheEntry.resolution` records it (`store(..., resolution:)`, default
     full); `SnapshotCaptureRequest.halfResolution` carries the set; `SnapshotCapturer` multiplies the backing
     scale by `resolution.scale` before `snapshotPixelSize` (the `SCStreamConfiguration` width/height).
  2. A half image flies like any other (`usableEntry` ignores resolution; no fallback or hole because of it).
     The overlay's image layer uses `contentsGravity = .resize`, which fills the layer bounds whatever the
     image's pixel size, so `contentsScale` (the screen's, shared with shadow/dim/ring) never sizes it: no
     change, comment added (the close ghost already sets `contentsScale` from the image, `CloseGhostOverlay`).
  3. Refresh: a shown-strip window whose current-size image is half resolution is selected
     (`SnapshotRefreshCause.halfResolution`, rank of a plain settle) by `snapshotStripSelection` and by
     `snapshotRefreshSelection(fullResolution:)` (the refresher passes the strip ids), so the settle after a
     switch re-captures the newly shown strip at full; a hidden window keeps any image it has (a full one from
     when it was shown stays).
  4. Cap: `snapshotCacheCapPixels(displayPixels:physicalMemory:)` = min(8 display-fulls, 3 % of the RAM at 4
     bytes a pixel); `SessionHost` passes `ProcessInfo.processInfo.physicalMemory` once
     (`SnapshotCacheRefresher.Context.physicalMemory`); debug `snapshot cache cap pixels=N ramMB=N` when first
     computed (again only if the displays change the value). Values: Air 13" (1470 x 956 @2x) 44,970,240 px
     (display-bound) on 8/16/24 GB; user's display 64,424,509 px on 8 GB (RAM-bound), 67,334,400 on 16/24 GB.
     The SM-21 strip pin still wins over it.
  5. Coverage: `enforce` evicts, within each protected/secondary class, full images of windows outside the
     strips before any half image and returns `[SnapshotEviction]` (id, resolution). A hidden window whose full
     image went is un-`tried`, so coverage captures it again at half; `snapshot coverage stopped` only when a
     half image had to go. `snapshot capture ...` gains `half=N` (half-resolution windows captured,
     `makeSnapshotSummary(half:)`).
  Expected memory [INFERENCE: window size from the last session, 56,439,696 px / 12 images = 4.70 Mpx, 0.56 of
  a display-full; 3 shown windows]: user's setup, 12 windows over 4-5 workspaces: shown 3 x 4.70 = 14.1 Mpx,
  hidden 9 x 1.18 = 10.6 Mpx, backdrop 8.4 Mpx: ~33 Mpx, ~132 MB (was ~65 Mpx at full, over the cap with any
  second size); after visiting every workspace hidden windows may keep full images up to ~65 Mpx (~260 MB),
  under the 67.3 Mpx cap, and past it the full hidden images go first and come back at half. 8 GB Air, same
  set: shown 3 x 3.14 = 9.4 Mpx, hidden 9 x 0.79 = 7.1 Mpx, backdrop 5.6 Mpx: ~22 Mpx, ~88 MB of a 45 Mpx
  (~180 MB) cap; the user's display on an 8 GB Mac stays at ~132 MB of a 64.4 Mpx (~258 MB) cap.
  RED (observed): `swift build --build-tests` with the Core change held back: `SnapshotPlanningTests.swift:488:36
  extra argument 'half' in call` (and the `summary.misses` lines after it); the compiler stopped at that file,
  so the other new tests (`SnapshotCacheTests`: `snapshotCacheCapPixels(displayPixels:physicalMemory:)`,
  `snapshotCaptureResolution`, `SnapshotResolution`, `store(resolution:)`, `.halfResolution`, `SnapshotEviction`;
  `SnapshotCacheRefresherTests`: `Context.physicalMemory`, `SnapshotCaptureRequest.halfResolution`) were
  compile failures not individually reported.
  Tests: Core `testCapIsTheSmallerOfEightDisplaysAndThreePercentOfTheRAM`,
  `testShownStripWindowsAreCapturedAtFullAndHiddenOnesAtHalfResolution`,
  `testAHalfResolutionImageFliesAndIsRefreshedOnceItsWindowIsShown`,
  `testEnforceEvictsFullImagesOfHiddenWindowsBeforeHalfOnes` (strip pin still wins), summary `half=1`; Session
  `testHiddenWorkspaceWindowsAreRequestedAtHalfResolutionAndTheShownStripAtFull`,
  `testASwitchedToWorkspaceIsCapturedAtFullResolutionAfterTheSettle`,
  `testAnEvictedFullImageOfAHiddenWindowComesBackAtHalfWithoutStoppingCoverage`, `testTheCapIsLoggedOnceAtStart`,
  `testATightRAMCapDropsHiddenImagesButNeverTheStrip`; re-pinned `testCoverageNeverEvictsTheVisibleImagesAndStopsAtTheCap`
  (30 hidden windows: two half-resolution stages fit, the second evicts half images and stops). The test fake
  returns half-size images for `halfResolution` windows.
  GREEN: full `swift test`: GioUITests 274 (53 skipped), GioSessionTests 371, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 50, GioCoreTests 1495, all 0 failures; `git diff --check` clean. Signed build: run by the parent.
  Not unit-tested (compile-checked): `SnapshotCapturer` per-window scale, `SessionHost` `physicalMemory`.
  LIVE PENDING: no `snapshot holes` on workspace switches (`Alt+U`/`Alt+I` through every workspace); switch slide
  sharpness acceptable with half-resolution windows; `snapshot capture ... half=H` during coverage and `half=0`
  for the settle after a switch; no `snapshot coverage stopped`; `snapshot cache ... pixels=P backdropPixels=B`
  near the estimate above and under `snapshot cache cap pixels=N`.

- [x] SM-23 (`5b038e0`, `241deda`) — No fixed wait before a retarget; log lines stamped to the millisecond.
  Report (2026-10-09): "a small delay on each focus change, the motion looks slightly stuck". Not
  reproduced: the log's one-second timestamps cannot show the latency between a key and its motion.
  1. `SnapshotFlightController.scheduleReflow` retargets on the next turn of the session queue
     (`scheduler.async`) instead of after `retargetDelay` (30 ms, removed). Keys already queued still merge
     into one retarget (`reflowScheduled`, `takeCoalescedReflow`); every key pressed while the overlay was up
     (flight or SM-14 hold) no longer waits 30 ms. [INFERENCE] the hold was perceptible on bursts; unproven
     until the live latency is read from the new timestamps.
  2. `GioLog` stamps each line to the millisecond (`2026-10-09T01:10:15.123Z`; the second's text stays
     cached, only the milliseconds are formatted per line). `parseLogTimestamp` (GioUI) reads both forms, so
     the Logs section keeps relative times for older files.
  3. Intermediate focus during a burst: no change. SM-12 already lets only the newest intent focus
     (`DispatchFocusBook`; `WriteLaneTests.testAnOlderFocusNeverLandsAfterANewerOne`,
     `testCollectNeverRunsAnOlderFocusOverANewerOne`). The remaining intermediate activations are keys whose
     lane focused before the next key arrived; skipping them would delay the keyboard focus (against FI-06).
  RED (observed): `SnapshotFlightTests.testBurstDuringFlightRetargetsAtOnceInOneReflow` (reflows 0, pending 1)
  and `testACoalescedReflowSurvivesTheDeferredWrites` (reflows 0) with the 30 ms hold;
  `GioLogTests.testALineIsStampedToTheMillisecond` (`2026-10-09T21:17:17Z`); `AdvancedPresentationTests.testRelativeTimes`
  (nil for a fractional stamp).
  GREEN: full `swift test`: GioUITests 306 (53 skipped), GioSessionTests 393, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 83, GioCoreTests 1655, all 0 failures; signed `xcodebuild` BUILD SUCCEEDED; `git diff --check`
  clean.
  LIVE (2026-10-09 21:20-21:24 UTC, build with `241deda`, one display, 398 Alt+H/J/K/L presses): the user
  reports it feels better. Key to first dispatched write: retarget during a flight p50 3 ms, p90 4, max 7
  (279 presses; at least 30 ms before by construction); a press that starts a flight (prime round trip) p50
  5 ms, p90 12, max 30 (59). Flights: 125, duration p50 403 ms. Not improved: main-thread hitches, 66/125
  flights without one (gio.log.1, before: 191/266); [INFERENCE] immediate retargets add main-thread work in
  bursts; the layers run on the render server, so a hitch is not a visible dropped frame by itself.

- [x] SM-24 (`123de82`) — An image of the window's current size flies whatever its age.
  Report (2026-10-09 21:29, "I think it happened again"). Log (`gio.log`, build with `241deda`): fine
  21:21-21:24 (active); then 3-4 min with only typing in one window, `snapshot cache pruned images=4 reason=age`
  (21:26:44) and `images=2 reason=age` (21:27:38); the next burst (21:27:41-45, Alt+1 then Alt+L/H across
  the strip) logged `snapshot retarget uncovered ids=1..3` 9 times, `snapshot holes ids=1..2` 6 times and
  `snapshot fallback reason=cache-miss ids=3..4` 4 times (`anim done ... renderer=ax`): parked strip windows
  without images popped in through holes or moved live through AX. A parked window cannot be captured again,
  so the age rule turned every idle pause past 180 s into holes (SM-09 had predicted "an idle pause over 180 s
  still falls back once"); the first settle after the burst (21:27:45.921) captured 7 windows.
  Decision (relax, no new state): `snapshotMaxAge` only marks an image stale. `usableEntry` returns the newest
  image of the start size at any age (another size still only within `snapshotSoftAge`, scaled); `prune` keeps
  current-size images (age prunes only images of a window without a frame); strip selection still re-captures
  stale strip images; coverage treats a stale hidden image like a missing one (`lacksFreshImage`, once until
  its workspace comes near, as a pruned one was); a memory-pressure warning still drops stale images of
  non-shown, non-adjacent workspaces. Tradeoff: a window not captured for a long time slides with old content
  for ~350 ms, then the real window shows. Removed: `snapshotEntryUsable` (no caller outside its test).
  RED (observed): `SnapshotCacheTests.testAnImageOfTheCurrentSizeFliesWhateverItsAge` (nil at 3600 s, pruned).
  Re-pinned to the decision: `testPruneDropsOnlyImagesNoFlightCanUse` (id 1 kept, `.age` 1),
  `SnapshotCacheRefresherTests.testSettlePrunesWhatNoFlightCanUseAndNeverRecapturesItInALoop` (stale hidden
  and adjacent images kept and flyable, no loop), `testAStaleHiddenWindowIsCapturedAgainWhenItsWorkspaceBecomesAdjacent`
  (was `testAPrunedHidden...`), `testStaleStripWindowsBeyondTheNeighbourColumnAreCapturedAgainAlthoughTried`
  (was `testPrunedStrip...`). Deleted (constant/removed-function pins): `testEntryIsUsableWhileFreshAndTheSizeStillMatches`,
  `testAgesAreBoringAndLarge`.
  GREEN: full `swift test`: GioUITests 306 (53 skipped), GioSessionTests 393, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 83, GioCoreTests 1654, all 0 failures; signed `xcodebuild` BUILD SUCCEEDED; `git diff --check`
  clean.
  LIVE PENDING: idle 4+ min (typing in one window is fine), then Alt+L/H across the whole strip and Alt+1/2:
  no `snapshot fallback reason=cache-miss`, `snapshot holes` only for windows never captured, no
  `snapshot cache pruned ... reason=age`.

- [x] SM-25 (`1d4f7b1`) — A placed window keeps both sizes; Alt+F back flies its own image.
  Report (2026-10-09 21:39, "it happened for a moment when I had a window full and then changed it to a
  column"). Log (build with `123de82`, session 21:36:42): `hotkey maximizeColumn` 21:37:03 (Tern `4907:4` to
  full width), `snapshot cache pruned ... reason=size` at 21:37:15 and 21:37:27 (the size a window is not at
  now, past the 30 s soft age), `hotkey maximizeColumn` 21:38:27.412 (back to a column), then
  `snapshot scaled id=4907:4` in 7 flights from 21:38:28.097 to 21:38:33.653: the maximized image squeezed
  into the column, while key presses kept a flight up and no settle could capture; `snapshot capture ...
  reason=size` only at 21:38:34.552. SM-11 keeps two sizes so Alt+F toggling finds both; the SM-20 size
  prune removed the other one 30 s later.
  Decision (relax): `prune` keeps every image of a placed window (age prunes only windows without a frame;
  the `size` prune reason is removed). Memory stays bounded by the cap, which already evicts the sizes a
  window is not at now first, and by memory pressure. Scaling another size stays limited to `snapshotSoftAge`.
  RED (observed): `SnapshotCacheTests.testBothSizesOfAWindowSurviveSettlesSoAToggleBackFliesItsOwnImage`
  (pruned `.size`, lookup nil). Re-pinned: `testPruneDropsOnlyImagesNoFlightCanUse` (id 2 keeps both sizes,
  no `.size`), `SnapshotCacheRefresherTests.testSettlePrunesWhatNoFlightCanUseAndNeverRecapturesItInALoop`
  (both sizes of b stay, nothing pruned).
  GREEN: full `swift test`: GioUITests 306 (53 skipped), GioSessionTests 393, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 83, GioCoreTests 1655, all 0 failures; signed `xcodebuild` BUILD SUCCEEDED; `git diff --check`
  clean.
  LIVE PENDING: Alt+F on a column, wait over 30 s, Alt+F back, then Alt+H/L right away: no `snapshot scaled`
  for that window; `snapshot cache entries ... pixels=` stays under the cap line.

- [x] SM-26 (`c0e6b46`) — The cap evicts every window's other size before any window's only image.
  Live check of SM-24/SM-25 (2026-10-09 21:43:32-21:46:52, build with `1d4f7b1`, 578 Alt+H/L, 44
  workspace switches, 39 Alt+F): 0 `snapshot fallback`, 0 `retarget uncovered`, 0 `cache pruned`; Alt+F
  back to a size already captured flew its own image (no `snapshot scaled` for Tern after 21:44:11, ~30
  toggles); `snapshot scaled` only on a window's first maximize of the session (never captured at that size),
  each followed by `snapshot capture ... reason=size`. New: `snapshot coverage stopped cap reached images=13`
  (21:45:43) and `evicted=1..2` at 21:45:43, 21:46:02, 21:46:07, then `snapshot holes ids=1` on every Alt+2/3
  switch from 21:46:28 to 21:46:32 (7 times; the 21:46:32 settle captured hidden `1923:2` and `50640:9` again).
  Cause: the second sizes SM-25 keeps (images=13 for 9 windows) filled the cap, and `enforce` evicted windows
  outside the refresh set first, so a hidden-workspace window lost its only image before a visible window lost
  its other size.
  Decision: `enforce` sorts secondary images (a size the window is not at now) of every window first, then
  SM-13's unprotected-before-protected, then the rest unchanged. A second size only helps an Alt+F back; a
  hidden window's only image serves every switch.
  RED (observed): `SnapshotCacheTests.testAnyWindowsOtherSizeGoesBeforeAHiddenWindowsOnlyImage` (the hidden
  window's image went first). Re-pinned: `testEnforceNeverEvictsTheStripsCurrentSizeImages` (order now the
  strip's other size, then the hidden window).
  GREEN: full `swift test`: GioUITests 306 (53 skipped), GioSessionTests 393, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 83, GioCoreTests 1656, all 0 failures; signed `xcodebuild` BUILD SUCCEEDED; `git diff --check`
  clean.
  LIVE (2026-10-09 21:50:19-21:51:30, build with `c0e6b46`, 208 Alt+H/L, 23 workspace switches, 2 Alt+F):
  `evicted=1` twice (21:51:04, 21:51:12) and 0 `snapshot holes`, 0 `retarget uncovered`, 0 `snapshot fallback`,
  0 `cache pruned`. 5 `snapshot scaled`, all for a size never captured: WhatsApp and LoopOps right after
  `min size learned` (21:50:26, captured 21:50:27), the first Alt+F of Tern and of WhatsApp (captured 1 s later).
  Still LIVE PENDING: the SM-24 idle path (no gap over 2 s between keys in this session).

- [x] SM-27 — Resize flights never stretch window content (niri-style clip and crossfade).
  Report (2026-10-11, Spanish): "como son imágenes, al querer hacer grande o reacomodar las cosas se ve un poco
  como que se estira". Log: `snapshot scaled id=5195:4`, `snapshot scaled id=30401:8` right after
  `hotkey maximizeColumn`. Cause: the image layer used `contentsGravity .resize` with the animated bounds, so
  every resize (and SM-11's other-size image) scaled the picture non-uniformly; a retarget that changed a
  layer's size stretched it too, without any log.
  Decisions (pure in `GioCore/Snapshot/OverlayResize.swift`; `GioUI` `SnapshotOverlay` only applies them):
  1. Never scale non-uniformly. The image layer is a clip (animated frame, corner radius 10, masked; shadow,
     dim, ring unchanged) whose bounds hang from its top-left corner (`overlayClipBounds`: origin `(0, -h)`,
     y up), so faces placed from the origin stay on the window's top-left while the bounds animate. A pure
     move with a matching image (2 pt) still draws it as the clip's contents (`overlayDrawsDirect`).
  2. Faces: each image at its own captured size (`SnapshotFace`; SM-22 half images scale uniformly ×2) over a
     solid fill out to the largest frame of the track (`overlayReach`, overshoot included). `OverlayCrossfade`:
     bottom face (start image) opaque; the target-size image (`SnapshotCacheUse.target`, any age like SM-24's
     start size) fades in on top. Curve: smoothstep over the resize progress (`overlayResizeProgress`: largest
     size change, clamped), done at `overlayCrossfadeSpan` = 60 %: with the default spring ~70 ms of a ~350 ms
     Alt+F, a dissolve over several frames without a lingering double exposure of two text layouts; the target
     image alone shows for the rest of the flight, so the last overlay frame is the landing size (no pop at the
     hand-off, which is unchanged).
  3. Missing target image (first maximize): `fill` (start image unscaled, flat fill where the frame outgrows it)
     or `crop` (shrinking: cut off, never squashed). Fill = per-channel median of 64 samples down a column 2 pt
     inside the right edge between the rounded corners, taken at capture off the session queue
     (`snapshotEdgeLine`/`snapshotEdgeFill` pure, `snapshotEdgeSamples` GioMacOS, stored in
     `SnapshotCacheEntry.fill`). Chosen over a 9-slice stretch of the last pixel row/column: text, scrollbars or
     sidebars crossing the edge smear into streaks, which reads as stretching again; the right edge crosses every
     band of the window in proportion to its height, so its median is the content background (the bottom edge is
     often a status bar). A see-through edge gets no fill.
  4. Retargets: the session hands each retargeted layer the image of its new size (`retargetFlight(images:)`,
     `SnapshotCacheRefresher.retargetFace`); the overlay evaluates the old track's progress at the elapsed time
     and starts the new opacities there (`retargeted(at:toward:)`), next to the carried velocity: same image ->
     the fade continues, a face it has -> the faces above fade out (Alt+F back mid-flight), a new one -> fades in
     on top, none -> fades to its face closest in size (`overlayClosestFace`).
  5. Log: debug `snapshot resize id=P:E mode=crossfade|fill|crop` at flight start and when a retarget changes a
     window's size; `snapshot scaled` is gone (`SnapshotCacheUse.scaled` renamed `otherSize`).
  RED (observed, compile): `OverlayResizeTests` (20 new: mode, curve, progress, crossfade state and retargets,
  keyframes, direct drawing, clip/face geometry, reach, edge line, median fill, face),
  `SnapshotCacheTests.testAResizeFlightGetsTheImageOfItsTargetSizeToCrossfadeTo`,
  `testWithoutTheTargetSizeTheStartImageFillsOrCrops`, `testAPureMoveNeedsNoResizeAndItsTargetIsTheSameImage`,
  `testAnEntryKeepsTheFillSampledFromItsEdge`, `SnapshotSamplingTests.testTheEdgeFillIsTheContentBackgroundBesideBarsAndRim`,
  `testATransparentOrTinyCaptureHasNoEdgeFill`, `SnapshotCacheRefresherTests.testCapturedFillsAreKeptAndBothSizesCrossfade`,
  `SnapshotFlightTests.testAResizingLayerCarriesTheImageOfItsTargetSizeAndEveryImageItsOwnSize`,
  `testARetargetGivesEveryLayerTheImageOfItsNewSize` (missing `OverlayCrossfade`, `snapshotResizeMode`,
  `SnapshotFace`, `fill:`...). Re-pinned: `.scaled` -> `.otherSize` (5 cache tests),
  `testWithoutAMatchingSizeAFreshImageFliesScaled` -> `...OfTheOtherSizeFlies` (mode `.fill`),
  `testFlightPrefersTheMatchingSizeAndFliesAFreshImageScaled` -> `...AndLogsHowItResizesWithoutStretching`.
  GREEN: full `swift test`: GioUITests 310 (53 skipped), GioSessionTests 431, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 92, GioCoreTests 1893, all 0 failures; signed `xcodebuild` BUILD SUCCEEDED; `git diff --check`
  clean. Not unit-tested (compile-checked): the Core Animation layer tree in `SnapshotOverlay` (`WindowLayers`,
  `FaceLayers`), the capture-time sampling call in `SnapshotCapturer`.
  LIVE PENDING (`docs/TESTING.md` 15h): with an editor, a terminal, a browser and a chat app, Alt+F (first
  maximize and again), Alt+F back and twice quickly, Alt+R presets, Ctrl+Alt+F, Alt+[ / Alt+], Alt+F then
  Alt+L, dwindle Alt+R / split toggle: text never looks stretched or squashed, the dissolve reads as a fade (not
  a pop, not a double exposure), no jump at the hand-off, the first-maximize fill matches the window background;
  log `snapshot resize ... mode=crossfade|fill|crop`, never `snapshot scaled`; pure scrolls unchanged; no new
  main-thread hitches in `anim done` for resize flights.

## Acceptance criteria
- Scroll/maximize/workspace animations visibly smooth at display refresh on Electron and native apps.
- Start latency (capture) logged; fallback to AX never leaves artifacts; overlay never stuck.
- All 5 bundles green; signed build OK; docs updated.

## Applicable checks
- TDD: STRICT ON. Runner `swift test` (read all 5 "Executed" lines).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: UNAVAILABLE (gentle-ai trailing-space path defect; user chose continue).

## Routes
SM-00..SM-02 one delegated writer; SM-03..SM-04 one delegated writer; SM-05 with the second or third.

### SM-15: snapshot becomes the default renderer (2026-10-08)
- User decision after the SM-08..SM-13 live sessions ("ponerlo como default y no experimental").
- `AnimationsSectionConfig.renderer` defaults to `.snapshot`; the config template writes `renderer = "snapshot"`;
  Settings > Animations lists Snapshot first with the Default badge and no Experimental badge (Accessibility has
  no badge); Diagnostics text no longer says experimental. Without Screen Recording (or on macOS 13)
  `effectiveRenderer` still falls back to `ax` and logs `renderer effective=ax reason=screen-recording-missing`.
- RED: `RendererSettingTests` default/unknown/template expectations changed to `.snapshot` first; 3 failures
  (`("ax") is not equal to ("snapshot")`). GREEN after the default change. Three GioUITests relied on the old
  default implicitly (`AdvancedPresentationTests` x2, `SettingsPresentationTests` round trip); they now set the
  renderer they test explicitly.
- LIVE PENDING: first launch without Screen Recording (Diagnostics shows the Fallback warning), and the
  SM-11..SM-14 behaviour on the build that carries them (the 2026-10-08 19:51 log came from the 18:45 build).

## Progress
- 2026-09-29: document created after live evidence. Next: SM-00..SM-02.
- 2026-09-29: SM-00..SM-02 done, pushed. Next: user measures capture latency; then SM-03/SM-04.
- 2026-09-29: measured (above); user accepted pre-capture + wallpaper backdrop tradeoff. Next: SM-02c, SM-03..SM-05 (route: one delegated writer, sequential commits).
- 2026-09-29: SM-02c..SM-05 done, pushed. Next: user live test of snapshot renderer.
- 2026-10-08: user chose the snapshot overlay as the primary motion path. SM-08 (overlay fidelity) and SM-09 (cache freshness) written in parallel, uncommitted; all bundles green. Next: signed build, then the user flips `renderer = "snapshot"` for the live test (15b).
- 2026-10-08: review of SM-08/SM-09 found 7 defects; SM-10 fixes all of them, uncommitted, all bundles green. Next: signed build, then the live test (15b) with the SM-10 LIVE PENDING list.
- 2026-10-08: live session (189 presses) showed 3 cache-miss fallbacks and 48 captures; SM-11 (coverage of every workspace, two sizes per window, attributed misses, parked misses not retried, focus is not dirt) uncommitted, all bundles green. Next: signed build, live check of the SM-11 LIVE PENDING list.
- 2026-10-08: SM-12 (flight latency: dispatched writes under the overlay, display-link frame measurement) written in parallel with SM-11, uncommitted, all bundles green. Next: signed build, then the live test with the SM-12 LIVE PENDING list.
- 2026-10-08: review of SM-11/SM-12 found 9 defects; SM-13 fixes all of them, uncommitted, all bundles green. Next: signed build, then the live test with the SM-12 and SM-13 LIVE PENDING lists.
- 2026-10-08: live report of blank windows after flights; SM-14 (non-opaque overlay panel, hand-off held until the windows that came from off screen or resized captured painted, cap 300 ms) uncommitted, all bundles green. Next: signed build, then the live test with the SM-14 LIVE PENDING list.
- 2026-10-08: live report of windows appearing late (empty desktop where they belong); SM-16 (windows without an image show through holes in the backdrop, no all-or-nothing fallback, holes paint-checked) uncommitted, all bundles green. Next: signed build, then the SM-16 LIVE PENDING list.
- 2026-10-08: same evidence showed Chrome/Code windows `ambiguous` (same size, parked at one frame, never visible); SM-17 (title tie-break: listed window name vs AX title, in memory only, learned afterwards) uncommitted, all bundles green. Next: signed build, then the SM-17 LIVE PENDING list.
- 2026-10-08: live screenshot showed a stale menu bar (app name, clock) during a flight; SM-18 (overlay panel covers the usable frame only, backdrop cropped with `contentsRect`) uncommitted, all bundles green. Next: signed build, then the SM-18 LIVE PENDING list.
- 2026-10-08: live session (519 presses) showed every hand-off held ~56 ms by the paint check; SM-19 (early paint check 80 ms before the deadline, per-app trust after 5 clean checks) uncommitted, all bundles green. Next: signed build, then the SM-19 LIVE PENDING list.
- 2026-10-08: same session showed a 307 MB cache of mostly unusable images and Chrome windows still `ambiguous` (equal titles); SM-20 (prune at each settle, memory-pressure source, cap 8 with backdrops counted, stacking-order tie-break never learned) uncommitted, all bundles green. Next: signed build, then the SM-20 LIVE PENDING list.
- 2026-10-08: live session (21:41 UTC) showed a system-wide memory-pressure warning purge the shown strip (43 holes in 34 flights after it, none before) and the dropped windows never re-captured (`tried`); SM-21 (warning is not a purge, strip coverage regardless of `tried`, recovery on normal, cap never evicts the strip) uncommitted, all bundles green. Next: signed build, then the SM-21 LIVE PENDING list.
- 2026-10-08: SM-08..SM-21 committed as `fa27a03` (with PF-I) and pushed to `main`. Last live session (21:57-21:59 UTC, 293 presses, 79/80 flights as images): fps median 117 (min 110), single flights with a hitch 20 %, hand-off wait 0 ms (max 12), 8 holes (after `snapshot coverage stopped cap reached images=12`), cache 259 MB. Open: hidden-workspace images vs the cap (half resolution or a higher cap), Xcode window `31952:13` refusing focus (-25201).
- 2026-10-08: SM-22 (hidden workspaces at half resolution, cap min(8 display-fulls, 3 % RAM), coverage stops only when a half image goes) uncommitted, all bundles green. Next: signed build, then the SM-22 LIVE PENDING list.
- 2026-10-08: SM-22 committed as `fdca808` and pushed. Live (22:33-22:35 UTC, 332 presses, 70 workspace switches): 93/94 flights as images (1 fallback: first motion after launch), fps median 117 (min 108), single flights with a hitch 15 %, 0 holes, no `coverage stopped`, cache 255-267 MB, cap `pixels=67334400 ramMB=24576`, Chrome matched `by=order`.
