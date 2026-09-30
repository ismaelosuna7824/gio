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

## Progress
- 2026-09-29: document created after live evidence. Next: SM-00..SM-02.
- 2026-09-29: SM-00..SM-02 done, pushed. Next: user measures capture latency; then SM-03/SM-04.
- 2026-09-29: measured (above); user accepted pre-capture + wallpaper backdrop tradeoff. Next: SM-02c, SM-03..SM-05 (route: one delegated writer, sequential commits).
- 2026-09-29: SM-02c..SM-05 done, pushed. Next: user live test of snapshot renderer.
