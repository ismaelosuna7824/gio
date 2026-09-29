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
- [ ] SM-00 — `[animations] resize` default -> "never" (stop the laggy first adaptive attempt).
- [ ] SM-01 — Screen Recording permission: preflight/request, Overview/Diagnostics status + button,
  `[animations] renderer = "snapshot" | "ax"` (default snapshot, auto-fallback to ax when missing).
- [ ] SM-02 — Capture module: SCShareableContent window matching (pid + frame, like FI-05),
  per-window + backdrop capture in parallel, time budget, `snapshot capture ms=` log, pure matching
  and budget decisions tested.
- [ ] SM-03 — Overlay renderer: per-display overlay window, backdrop + window layers, CA spring
  animations (position + bounds), retarget from presentation values, teardown.
- [ ] SM-04 — Orchestration: motion start -> capture -> overlay + single real write -> settle ->
  remove overlay; rapid retargets reuse layers, newly involved windows captured on demand; focus ring
  and focus intent timing preserved; workspace switch + maximize + scroll paths.
- [ ] SM-05 — Safety + docs: watchdog, fallback matrix, memory limits (release images), docs.

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
