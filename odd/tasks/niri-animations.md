# Niri animations: open/close and per-animation tuning

## Objective
Cover the Niri animation set that Gio still lacks, with Niri-like per-animation configuration:
window open, window close, and independent tuning of view movement, window movement, workspace
switch, open and close.

## Problem
Gio animates horizontal view movement, column moves, workspace switches and maximize (native zoom),
all with one global `[animations]` spring/curve. A newly opened window pops in wherever the app put
it and then jumps into its column; a closed window vanishes and (to verify) neighbours may jump to
fill the gap. Niri has `window-open`, `window-close`, `horizontal-view-movement`,
`window-movement`, `workspace-switch`, `window-resize` animations, each configurable.

## Why
User roadmap (2026-09-30): after the live test and SessionHost refactor, "lo que falta de niri de
las animaciones". Refactor live-validated ("parece que va bien").

## Constraints
- AX renderer default (real windows): position-only per frame (FI-03), sizes at safe ends, no
  per-frame resizes; a closed window no longer exists (no AX motion possible).
- Optional visual extras that need Screen Recording (snapshot images) must be opt-in and degrade to
  AX-only behaviour; no full-screen backdrop overlays (they flickered, SM-07).
- Logic in GioSession/GioCore with tests (ReflowPlanner, MotionDriver, ActionApplier patterns);
  only WindowReconciler writes; Gio never manages its own pid; logs never titles.
- Conventional Commits, NO Co-Authored-By; push after verified batches; no PR.

## Tasks
- [ ] NA-01 — Audit: which transitions animate today (open, close, move column, consume/expel,
  width presets, workspace move, minimize/restore) and gaps; record findings.
- [ ] NA-02 — Window open: new window's column inserted with neighbours sliding to make room; the
  window itself enters from a short offset (e.g. rises ~24pt / slides from its side) with the spring
  into its slot instead of jumping from the app's initial frame; first placement write hides the
  app's initial position as fast as possible.
- [ ] NA-03 — Window close: neighbours glide to close the gap (spring), focus moves smoothly;
  optional "close ghost" (cached snapshot of the closing window fading/shrinking ~150ms in a tiny
  window-sized click-through layer) only when Screen Recording is granted and enabled.
- [ ] NA-04 — Per-animation config (Niri names): `[animations.horizontal-view-movement]`,
  `[animations.window-movement]`, `[animations.workspace-switch]`, `[animations.window-open]`,
  `[animations.window-close]`, `[animations.window-resize]` each with `enabled`, `curve`, spring
  params / duration, inheriting the global `[animations]` defaults; Animations settings UI with an
  expandable per-animation list and preview.

## Acceptance criteria
- Opening and closing windows animate smoothly live; per-animation settings apply live.
- All bundles green; signed build OK; docs updated.

## Applicable checks
- TDD: STRICT ON. Runner `swift test` (read every bundle line).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.

## Routes
NA-01..NA-04: one delegated writer (audit first, then implementation commits).

## Progress
- 2026-09-30: document created. Next: NA-01..NA-04.
