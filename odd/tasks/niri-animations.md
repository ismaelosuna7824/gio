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
- [x] NA-01 (`4f721e0`) — Audit: which transitions animate today (open, close, move column, consume/expel,
  width presets, workspace move, minimize/restore) and gaps; record findings.
- [x] NA-02 (`5203832`) — Window open: new window's column inserted with neighbours sliding to make room; the
  window itself enters from a short offset (e.g. rises ~24pt / slides from its side) with the spring
  into its slot instead of jumping from the app's initial frame; first placement write hides the
  app's initial position as fast as possible.
- [x] NA-03 (`1dc1c3c`) — Window close: neighbours glide to close the gap (spring), focus moves smoothly;
  optional "close ghost" (cached snapshot of the closing window fading/shrinking ~150ms in a tiny
  window-sized click-through layer) only when Screen Recording is granted and enabled.
- [x] NA-04 (`9b92741`) — Per-animation config (Niri names): `[animations.horizontal-view-movement]`,
  `[animations.window-movement]`, `[animations.workspace-switch]`, `[animations.window-open]`,
  `[animations.window-close]`, `[animations.window-resize]` each with `enabled`, `curve`, spring
  params / duration, inheriting the global `[animations]` defaults; Animations settings UI with an
  expandable per-animation list and preview.
- [x] NA-05 (commit pending, branch `fix/johan-spaces-safari`) — Resizes instant by default (user, 2026-10-15,
  after SM-32..SM-34 and three 120 fps recordings of `Alt+F` on Postman: no flashing frame left, the content
  jump from one layout to the other is inherent to animating a size change with window images; tried
  `[animations.window-resize] enabled = false` in the user's config live, "me parece mejor", default but
  configurable from the app). `AnimationKind.enabledByDefault` (false only for `window-resize`) is the
  fallback of `resolved(_:)`, of the Settings row (`AnimationKindForm.kind`, `enabled = own.enabled ??
  default`; the override writes `enabled` only when it differs from the default, so `true` is written to turn
  resizes on and the key goes when off again) and of the row preview. Config template and USER_GUIDE document
  the table and the default; the user's temporary override was removed again (config byte-identical to before).
  RED: `PerAnimationConfigTests.testResizesAreInstantByDefault...`, `testEveryKindInherits...`,
  `SettingsPresentationTests.testTheResizeRowIsOffByDefault...` failed; GREEN after; the planning test that used
  `window-resize` as its animated fallback now uses `window-movement`. Snapshot `na04-animations-per-animation`:
  "Window resize · Off: instant", switch off. Bundles UI 311 (53 skipped) / Session 481 / POC 7 / Mac 19 /
  MacOS 95 / Core 1963, 0 failures; signed build OK. LIVE PENDING: Alt+F instant without the config line; the
  Window resize switch turns the animation back on.

Evidence (route: delegated writer, opus): audit — all transitions already animated via reflowAll;
open used to fly from the app's frame at app size. NA-02 entry from below at final size (rise <=
1/4 height, may hang past bottom edge), skipped for parked/hidden/instant. NA-03 neighbours glide
(already true) + opt-in close ghost (cached image <=120s at current frame, max 4, 150ms fade+6%
shrink, no backdrop; light post-settle cache when ghost on). NA-04 per-animation sections with Niri
names, dominant-cause classification, UI card. Bundles 179(44 skipped)/216/7/19/39/1172 all 0
failures (parent re-ran); signed build OK. Risk: entry pre-position write may block session queue
up to 0.3s mid-motion. LIVE PENDING.

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
- 2026-09-30: NA-01..NA-04 done, pushed. Next: named workspaces.
