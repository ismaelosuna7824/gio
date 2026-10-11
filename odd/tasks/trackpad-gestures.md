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

## Tasks
- [x] TG-01 — Swipe recognizer (finger count, centroid, commit threshold, axis lock,
  80 ms velocity, finger-count rules) and the touch frame gate. Commit: see Progress.

## Evidence
- TG-01: RED `swift build --build-tests` failed (`cannot find 'GestureRecognizerSettings' in
  scope`, `cannot find type 'TouchFrame' in scope`); GREEN
  `swift test --filter GioCoreTests.GestureRecognizerTests`: 15 tests, 0 failures.

## Progress
- TG-01 committed (hash recorded in the follow-up docs commit).
