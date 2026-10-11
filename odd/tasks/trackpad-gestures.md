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

## Tasks
- [x] TG-01 — Swipe recognizer (finger count, centroid, commit threshold, axis lock,
  80 ms velocity, finger-count rules) and the touch frame gate. Commit `4df4437`.
- [x] TG-02 — `[gestures]` table: parse, validate (warnings keep defaults, finger conflicts),
  template, Settings card and form. Commit: see Progress.

## Evidence
- TG-01: RED `swift build --build-tests` failed (`cannot find 'GestureRecognizerSettings' in
  scope`, `cannot find type 'TouchFrame' in scope`); GREEN
  `swift test --filter GioCoreTests.GestureRecognizerTests`: 15 tests, 0 failures.
- TG-02: RED `swift build --build-tests` failed (`cannot find 'GesturesSectionConfig' in
  scope`); GREEN `GesturesConfigTests` 10 tests plus the existing config, patcher, template
  and Settings presentation tests, 0 failures.

## Progress
- TG-01 committed `4df4437`.
- TG-02 committed (hash recorded in the follow-up docs commit).
