# Trackpad gestures: scroll the strip, switch workspaces, open the overview

## Objective
Swipe with three fingers to scroll the column strip the way niri does on a touchpad: the
strip follows the fingers 1:1, and on release it springs to a column boundary with the
velocity of the swipe. Swipe vertically to change workspace; optionally swipe up with four
fingers for the workspace overview.

## Scope (user choice 2026-10-11, OmniWM comparison)
Bring OmniWM's trackpad gestures to Gio. The user allowed private APIs with a runtime probe
and a fallback: without them Gio keeps working exactly as before. Non-goals: OmniWM's
four-finger window move and resize, momentum (free deceleration) scrolling, mouse-wheel strip
scrolling. Reference: the OmniWM evaluation (`GesturesEval`) and OmniWM's
`Core/Multitouch`, `MouseEventHandler+Trackpad*`, `AnimationDriver` and `SwipeTracker`. OmniWM
is GPL-2.0: read for behavior and mechanism only, no code copied. niri's
`src/layout/scrolling.rs` (`view_offset_gesture_end`) and `src/input/swipe_tracker.rs` were
read for the snap and focus rules.

## Decisions
- TG-01 recognition (pure, `GioCore/Gestures/GestureRecognizer.swift`): the input is a
  `TouchFrame` (timestamp, contacts with normalized x/y, y up) and the output a
  `TrackpadGestureEvent`. A finger count with a configured gesture starts tracking at the
  frame it is reached, so the centroid jump of a landing finger is never movement. The axis
  locks once the centroid travels `commitDistance` (0.03 of the trackpad, about 3 mm on a
  laptop trackpad); the larger component wins. Horizontal with the scroll count scrolls
  (`scrollBegan`, then `scrollChanged(dx)` per frame, the first one carrying the whole travel
  so the strip matches the fingers), vertical with a vertical count emits one
  `verticalSwipe` per touch-down; an axis without a gesture consumes the touch-down (a
  vertical start never turns into a scroll later). Finger-count changes: before the commit
  any change restarts recognition; while scrolling an extra finger cancels
  (`scrollCancelled`: the gesture is abandoned) and lifting a finger ends it
  (`scrollEnded(velocity)`): fingers rarely lift in the same frame, so "any change cancels"
  would cancel nearly every release. A consumed touch-down is released once fewer fingers
  than any gesture needs remain.
- TG-01 velocity: `SwipeVelocityTracker` keeps 80 ms of samples (OmniWM's window; niri uses
  150 ms) and returns the travel between the oldest and the newest sample in the window over
  their time. The release frame is pushed as a sample, so fingers that rested before lifting
  end with no velocity.
- TG-01 frame gate: a resting finger makes the trackpad report frames at its rate (pointer
  movement, two-finger scrolling). `TouchFrameGate` lets through only frames with at least
  the smallest configured finger count, plus the one frame that drops below it, so pointer
  movement never reaches the session queue.
- TG-02 config `[gestures]` (`GioCore/Config/GesturesConfig.swift`): `scroll` (true),
  `scroll-fingers` (3), `scroll-sensitivity` (1.0 screen widths per trackpad width, 0.1-5.0),
  `natural` (true, applies to scroll and workspace swipe), `workspace-swipe` (true),
  `workspace-fingers` (3), `overview` (false), `overview-fingers` (4). Unlike the other
  tables, an invalid value is a warning that keeps the key's default (the assignment's rule:
  a gesture typo must not set the whole file aside); an out-of-range sensitivity is clamped
  with a warning like the other numbers. Finger counts are 3-5: two fingers are the system's
  scrolling, which Gio would have to swallow from the event stream (a filtering `scrollWheel`
  tap: Input Monitoring, tap timeouts, and every app's scrolling through Gio's tap), so no
  swallowing is needed at all. Conflict rule: the workspace swipe and the overview both swipe
  vertically, so the same count for both (both on) is rejected after the file is read: the
  workspace swipe keeps its fingers, the overview is turned off, one warning. Scroll and a
  vertical gesture may share a count (the axis lock tells them apart). The overview is off by
  default because macOS maps four fingers up to Mission Control unless the user moved it
  (and three fingers up by default). Settings: a Trackpad Gestures card in Focus (same draft
  and Apply bar; `GesturesSettingsForm` validates and patches, comments kept).
- TG-03 input source (`GioMacOS/Gestures/Multitouch.swift`): private `MultitouchSupport`
  through `dlopen`/`dlsym` (`MTDeviceCreateList`, `MTDeviceStart`, `MTDeviceStop`,
  `MTRegisterContactFrameCallbackWithRefcon`, `MTUnregisterContactFrameCallback`; the plain
  `MTRegisterContactFrameCallback` is not needed once the refcon variant exists). A missing
  symbol: `gestures available=false reason=missing-symbols:<names>` once (the facts log gate,
  like `skylight`), gestures off, nothing else changes. Contact records are read as the
  publicly reverse-engineered 96-byte `MTTouch` (identifier at 16, state at 20, normalized
  position at 32/36, y up); `makeTouch` (3) and `touching` (4) count as fingers on the
  surface. [INFERENCE] y grows upward and the states are as documented by open-source
  trackpad tools; the swipe direction is LIVE PENDING. The callback copies the frame and
  posts it; it never touches session state. Devices are registered on the main thread from a
  fresh device list; `MultitouchDeviceWatcher` (IOKit first-match and terminated
  notifications for `AppleMultitouchDevice`, present on this Mac per `ioreg`, plus
  `NSWorkspace.didWakeNotification`) re-registers 1 s after the last change. With every
  gesture off the devices are stopped (and the mailbox gate lets nothing through). The
  source stays alive until exit: its refcon is unretained and a callback may run while
  `stop()` returns.
- TG-03 permissions: Gio adds no `scrollWheel` (or gesture) event to the tap and swallows
  nothing, so the tap's permissions are unchanged. [INFERENCE] MultitouchSupport contact
  callbacks need no Input Monitoring grant for an app that already has Accessibility (other
  trackpad tools read it the same way); not verified here (the user's Gio is running and
  must not be disturbed). LIVE PENDING: `gestures first contact frame` (logged once at info)
  must appear after the first three-finger swipe; if it never does, Input Monitoring is the
  first suspect (documented in USER_GUIDE).
- TG-03 mailbox (`GioSession/Gestures/TouchFrameMailbox.swift`): a locked buffer, the
  `TouchFrameGate` applied under the lock, one drain scheduled per burst on the session
  queue (`SessionScheduler.async`), every frame delivered in order (velocity needs them all);
  past 256 pending frames the oldest are dropped, the callback never blocks. Pacing: the
  strip is laid out once per drain (the trackpad's rate, coalesced when the queue is busy),
  not by a display timer: a timer would only resample the same last finger position.
- TG-03 interactive viewport: the scroll acts on the display under the pointer (else the
  focused display), as the pointer is where the user looks; the trackpad has no position of
  its own. A workspace showing a fullscreen window does not scroll. The gesture starts from
  where the windows really are (`gestureVisualOffset`: a running motion is stopped, and the
  strip is picked up where it was drawn). The offset is clamped to the strip and re-based at
  the ends (niri clamps its gesture too; no rubber band). Each drain lays the strip out at
  the offset with no reveal, `planParking` parks what left and un-parks what arrived (no
  focused-column exemption: the fingers own the view), and `GestureFramePump` writes the
  changed windows. State (offset, focus) does not change until the release; every pass
  returns at once while tracking and the release or the abandon runs one that covers them.
- TG-03 transport (the assignment asked for the fastest available one; decision): SkyLight per
  drain for every changed window (one transaction; a scroll only moves, never resizes), else
  the apps' Accessibility motion lanes; not the snapshot overlay. The overlay primes
  asynchronously on main (the first finger frames would be late), parked columns' images
  can be missing or stale (the cache refreshes after settles; a column entering mid-gesture
  would show an old picture or none), and the real windows still need a write under it at
  the end, which is where the velocity hand-off has to happen. Invariant 3: the pump calls
  the reconciler's `submitWindowServerMotion` and `submitMotion`, the same entry points as
  `MotionPlayer` (the gesture is a motion lane of its own driven by the fingers). Invariant
  10: SkyLight-moved windows stay in the reconciler's ledger until the settle's final pass
  writes them through Accessibility; an abandon's pass does the same. PF-K: the Accessibility
  lanes switch `AXEnhancedUserInterface` off at their first frame as for any motion, and
  every settle ends with `restoreEnhancedUI`. The gesture's pids are animating (moved events
  dropped as echoes), the dim hides and render checks wait as during a motion.
- TG-03 release (niri `view_offset_gesture_end`, read in niri's source): the offset is
  projected with the release velocity over `gestureProjectionSeconds` (0.333 s, niri's
  touchpad deceleration 0.997 per ms), the nearest snap point wins (each column's left edge
  minus the padding and right edge plus the padding against the viewport, only between the
  first column's left and the last column's right, which the clamp turns into 0 and the
  maximum offset; with `center-focused-column = always` each column centered), then the
  focus moves on to the furthest column still fully visible in the swipe's direction (niri's
  rule). The snap points match `revealOffset`'s padding, so the reveal of the settle pass
  leaves them alone. `commitGestureScroll` writes offset and focus into State and focuses the
  swiped display; the session runs one animated pass (`.viewScroll`, horizontal-view-movement
  settings) whose springs start with the release velocity (`handingOffGestureVelocity`), on
  the motion player even when the snapshot renderer is configured (the overlay flies from
  rest), with every same-size flight on SkyLight (`planMotionTransports(moveVisible:)`,
  continuing the gesture's transport). Animations off or an instant placement pending: the
  settle is instant.
- TG-03 focus (assignment question "does niri focus the column after a gesture?"): yes, niri
  sets the active column to the snapped one (`self.active_column_idx = new_col_idx`), and the
  active column is the keyboard focus. Gio does the same: the settle that focused another
  window raises it through `FocusCoordinator.requestGestureIntent()` (a focus intent like a
  key press), without the centering request (the snap chose the offset) and without the
  `mouse-follows-focus` warp (the hand is on the trackpad). The gesture counts as a
  deliberate input like a key press; passive paths still never focus. Nothing is focused
  while the fingers move.
- TG-03 mouse and cancel: an extra finger abandons (`gesture scroll abandoned
  reason=cancelled`): State untouched, `reflowAll()` animates the strip back. A mouse button
  down (a click, or three-finger drag) abandons like a mouse-abandoned flight: State
  untouched, `InstantPlacementGate` armed (`.mouse`), the pass lands instantly once the button
  is up; a scroll never starts while a button is down.
- TG-03 vertical swipes: discrete, one action per touch-down. `workspaceSwipeAction` maps
  (natural) up to `focus-workspace-down` and down to `-up`, applied through `apply` exactly
  like the hotkey (so its focus intent and motion are the hotkey's). The overview's swipe is
  up only and toggles it on main like `Alt+O`. Interactive workspace progress (OmniWM's
  rubber-banded `WorkspaceSwipeMotion`) was optional and is not done.
- TG-03 Diagnostics: `SessionFacts.gestures` (`gestureSourceStatus`: `not-loaded`,
  `missing-symbols:<names>`, `config-off`, `no-trackpad`, `devices=N`) and a Gestures card.
- TG-04 conflicts (`GioCore/Gestures/GestureConflicts.swift`, pure): from the integer values
  of `com.apple.AppleMultitouchTrackpad`, `com.apple.driver.AppleBluetoothMultitouch.trackpad`
  (`TrackpadThreeFinger{Horiz,Vert}SwipeGesture`, `TrackpadFourFinger{Horiz,Vert}SwipeGesture`,
  `TrackpadThreeFingerDrag`) and `com.apple.dock` (`showMissionControlGestureEnabled`,
  `showAppExposeGestureEnabled`). A swipe is on when any trackpad domain holding the key
  says so (the built-in and a Magic Trackpad share the swipe, and System Settings writes
  both); a key missing from every domain is macOS's default (2 for the four swipes, Mission
  Control on, App Exposé and three-finger drag off): a false warning is cheaper than a
  silent fight. Horizontal 3 fingers: 2 = full-screen apps, 1 = swipe between pages;
  4 fingers: 2 = full-screen apps; vertical 3/4 = 2: Mission Control (if on) for the
  workspace swipe and the overview, App Exposé (if on, it swipes down) for the workspace
  swipe only; three-finger drag against every three-finger gesture; five fingers against
  nothing. Only enabled gestures count; none when MultitouchSupport is missing. The
  adapter (`GioMacOS/Gestures/TrackpadPreferences.swift`) synchronizes each domain and
  reads with `CFPreferencesCopyAppValue`, never writes; numbers and booleans become
  integers, anything else counts as missing. Re-read: at most every 10 s while the facts
  are built (UI polling only, no timer) and on every config apply (a reload or a Settings
  Apply re-reads at once). Shown in Diagnostics > Gestures (warning, `N conflicts`, one
  detail per conflict), the Overview status card and the Settings Trackpad Gestures card
  (for the saved config), each with the exact System Settings path; logged
  `gestures conflict=<gesture-fingers:system,...>` (warn) or `gestures conflict=none` (info)
  once and on change, no titles. This Mac reads 2 for all four swipe keys in both domains
  (the macOS defaults), so the default gestures report two conflicts.
- Dwindle (rebased onto DW-01..DW-04): a dwindle workspace has no strip, so
  `gestureStrip` returns nil (`layout == .dwindle`) and a horizontal scroll does nothing
  (debug `gesture scroll ignored ... reason=no-strip`); the workspace swipe and the overview
  swipe go through `apply` / the overview hook and work there unchanged.
- TG-05 WindowServer drift after a swipe (live 2026-10-11T22:53Z, `~/.config/gio/gio.log`,
  display 1800x1169, four 888 pt columns, snapshot renderer, SkyLight verified). Every
  `render mismatch` of the session followed a gesture settle, none a keyboard flight. Gesture
  A (`begin offset=919`, `end offset=1117 snap=1815`): final pass `applied=2 parked=1
  already=1`, then `render mismatch id=4295:8 app=Code ax=(904,8,888,1114) ws=(-928,8,..)`
  and `id=57880:6 app=Tern ax=(8,8,..) ws=(-1824,8,..)`; gestures C and E left Safari and
  Xcode at `ws=(-25,8,..)` for `ax=(8,8,..)`; every position and size nudge `fixed=false`, so
  four windows ended render-unverifiable and stayed drawn off screen. Candidates from the
  assignment, checked against the code and `WindowServerAlignmentTests`: (a) a stale
  transaction after the final pass: none exists (the pump commits only while tracking, the
  player only on ticks, the final pass runs synchronously in the last tick; the test's
  journal shows nothing committed after the final writes); (b) a coordinate error: every
  frame SkyLight was given lies between the window's start and its target in screen space
  (the gesture frames and the settle use the same engine layout; the critically damped spring
  with the release velocity pointing at the target does not overshoot), so -33 and -1832 are
  no frame Gio computed; (c) confirmed: the final pass took the app's word for the
  WindowServer. Before the fix (`72e97e9`) `LaneWorker.reconcileOne`
  (`Reconciler.swift:242-253`) wrote the follow-up and read the position back from the app,
  `ledger.followed` (`:332`) folded the window and the pass ended there with no WindowServer
  step, `TrustedFrames.recordSettle` trusted it, and nothing compared the WindowServer with
  the target again except the render check, whose only tool was an Accessibility nudge
  (`RenderVerifier.swift:157-206`). The log shows that an app reporting the target does not
  move the WindowServer when written again (two nudge tiers, four windows). [INFERENCE] How
  the WindowServer and the apps drifted apart (Gio's rapid transactions racing the app's own
  reaction to the follow-up write) is not observable from Gio, and the test's fake app (moves
  its window by the change it sees, unaware of SkyLight) reproduces the signature, not the
  exact offsets. Fix (decision): after
  the follow-up writes returned, `reconcile` commits one more transaction moving every window
  whose ledger entry it folded and whose write landed to exactly the frame the app took
  (`alignWindowServer`; the clamped landing for a clamped park); nothing becomes pending
  because the app already holds that frame, so invariant 11 keeps its meaning (the app's
  frame is the final word, now applied to the WindowServer too). Only folded windows are
  aligned (`WindowServerLedger.followed` returns them), so a newer move is never undone.
  `collect` (passes under a snapshot overlay) does not align: a newer pass may already have
  written the window on its lane; the gesture settle never uses the overlay. Repair: the
  render check moves a window with a WindowServer entry away from its app's frame through
  SkyLight to that frame first (`planRenderRepairs`, pure), re-checks after 100 ms and logs
  `render repair id= app= via=skylight fixed=`; a failed or refused repair, a `ws=missing`
  window and every mismatch without SkyLight go to the position then size nudge as before
  (one chain per window per settle). The fix lives in the SkyLight transport, so it applies to
  every `reconcile` pass that followed SkyLight moves (PF-L parks and reveals, PF-M flights),
  recorded as PF-N in `fluidity.md`.

## Tasks
- [x] TG-01 — Swipe recognizer (finger count, centroid, commit threshold, axis lock,
  80 ms velocity, finger-count rules) and the touch frame gate. Commit `1a5935d`.
- [x] TG-02 — `[gestures]` table: parse, validate (warnings keep defaults, finger conflicts),
  template, Settings card and form. Commit `8c41d40`.
- [x] TG-03 — MultitouchSupport source, touch mailbox, interactive strip scroll through the
  reconciler (SkyLight per drain, AX lanes fallback), niri snap, State commit, velocity
  hand-off, gesture focus intent, workspace and overview swipes, Diagnostics card. Commit
  `50d64dd`. LIVE PENDING (see below).
- [x] TG-04 — macOS swipe conflicts from the trackpad and Dock preferences (pure Core, read-only
  adapter), warnings in Diagnostics, Overview and Settings, `gestures conflict=` log; no
  scroll on dwindle workspaces. Commit `ae25e26`. LIVE PENDING (TESTING.md 15i (j), (k)).
- [x] TG-05 — After a swipe the WindowServer drew windows 33-1832 pt from the frames their apps
  reported; the final pass now aligns the WindowServer with every followed-up window, and
  the render check repairs drawn mismatches through SkyLight before nudging (PF-N). Commit
  `b2ed03e`. LIVE PENDING (TESTING.md 15i (l), 15h).

## Evidence
- TG-01: RED `swift build --build-tests` failed (`cannot find 'GestureRecognizerSettings' in
  scope`, `cannot find type 'TouchFrame' in scope`); GREEN
  `swift test --filter GioCoreTests.GestureRecognizerTests`: 15 tests, 0 failures.
- TG-02: RED `swift build --build-tests` failed (`cannot find 'GesturesSectionConfig' in
  scope`); GREEN `GesturesConfigTests` 10 tests plus the existing config, patcher, template
  and Settings presentation tests, 0 failures.
- TG-03: RED `swift build --build-tests` failed (`cannot find 'gestureStrip' / 'GestureSnap' /
  'commitGestureScroll' / 'handingOffGestureVelocity' in scope`, `cannot find
  'GestureFramePump'`, `'GestureSourceStatus'`, `'MultitouchSymbols'`, `'TouchFrameMailbox'`,
  `type 'GestureController'`); `AdvancedPresentationTests` failed on the missing Gestures
  card. GREEN: `StripGestureTests` 18, `GestureFramePumpTests` 4, `GestureStatusTests` 3,
  `MultitouchTests` 4, `TouchFrameMailboxTests` 4, `GestureControllerTests` 10,
  `FocusCoordinatorTests` +1, `SessionPublicationTests` +1, `AdvancedPresentationTests` +1.
  Full `swift test`: GioUITests 309 (53 skipped), GioSessionTests 416, GioPOCTests 7,
  GioMacTests 19, GioMacOSTests 93, GioCoreTests 1779, 0 failures. Signed `xcodebuild`
  (`Gio` scheme, Debug, arm64): BUILD SUCCEEDED.
- TG-03 LIVE PENDING (not run: the user's Gio is running on this desktop, and nothing that
  captures input or moves windows may run here): TESTING.md row 15i, steps (a)-(i).
- TG-04: RED `swift build --build-tests` failed (`cannot find 'detectGestureConflicts' /
  'GestureConflict' / 'SystemTrackpadGesture' / 'gestureConflictMessage' /
  'GestureConflictLogGate' in scope`, `cannot find 'preferenceValues' /
  'readTrackpadSystemPreferences'`); `StripGestureTests.testNoStripOnADwindleWorkspace`
  failed (a strip was returned). GREEN: `GestureConflictTests` 9, `StripGestureTests` 19,
  `TrackpadPreferencesTests` 2, `SessionFactsBuilderTests` +1, `AdvancedPresentationTests` +1.
  Full `swift test` after TG-04 (on the Dwindle rebase): GioUITests 311 (53 skipped),
  GioSessionTests 424, GioPOCTests 7, GioMacTests 19, GioMacOSTests 95, GioCoreTests 1875,
  0 failures. Signed `xcodebuild` BUILD SUCCEEDED; `git diff --check` clean.
- Input Monitoring is still unverified: TESTING.md 15i starts by recording whether
  `gestures first contact frame` appears with Gio off, then on, in Input Monitoring.
- TG-05: RED (behavior, against the unchanged reconciler, the new tests that compile there):
  `WindowServerAlignmentTests.testAGestureSettleEndsWithTheWindowServerDrawingEveryWindowAtItsTarget`
  (Tern drawn at `(-888,8,888,1114)` while the app reported 8, Code at 9 for 904; nothing
  committed after the final writes; every committed frame on its path) and
  `testOnlyLandedFollowUpsAreAlignedAndAFailedOneStaysPending` (last line `write 57880:6@8`,
  Tern drawn at -1783), 5 failures; RED (compile) for the rest: `alignWindowServer`,
  `planRenderRepairs`, `renderRepairLine` not found, `RenderVerifier.Context` extra arguments
  `windowServerAvailable`/`alignWindowServer`. GREEN: `WindowServerAlignmentTests` 7,
  `RenderVerifierTests` 16 (+4); updated to the aligned contract:
  `WindowServerTransportTests.testParksAndRevealsCommitOneTransactionBeforeTheirAXWrites`,
  `testTheAXFollowUpIsWrittenEvenWhenTheAppAlreadyReportsTheTarget`,
  `WindowServerMotionTests.testMotionFramesAreOneTransactionAndTheFinalPassFollowsWithAX`
  (each now ends with the alignment commit). Full `swift test`: GioUITests 311 (53 skipped),
  GioSessionTests 428, GioPOCTests 7, GioMacTests 19, GioMacOSTests 95, GioCoreTests 1882,
  0 failures. A rerun after comment-only edits failed only
  `GioUITests.LauncherPanelAnimationTests` (an AppKit slide-in, untouched code) while the
  display was asleep (`pmset -g log`: display off 16:24:46 local); with the display awake
  GioUITests 311 (53 skipped), 0 failures, the other bundles as above. Signed `xcodebuild`
  (`Gio` scheme, Debug, arm64): BUILD SUCCEEDED; `git diff --check` clean. Not run live (the
  user's Gio is running; nothing that moves windows may run here).

## Progress
- TG-01..TG-03 rebased by the coordinator onto main with Dwindle (DW-01..DW-04): `1a5935d`,
  `8c41d40`, `50d64dd`, docs `fdefbbb` (the pre-rebase hashes `4df4437`, `e5b29b7`,
  `bb7b169`, `7cfe28f` are gone).
- TG-04 committed `ae25e26`.
- TG-05 (with PF-N) committed `b2ed03e` on `main`, not pushed; LIVE PENDING.
