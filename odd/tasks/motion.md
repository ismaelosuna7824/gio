# Motion: performance and animation (phases 2 + 4 of live-issues plan)

## Objective
Scrolling and focus moves feel Niri-like: fast, smooth, animated, with no window
popping in or lagging behind, while tiling stays correct.

## Problem (diagnosis 2026-09-29, engram "Gio live issues diagnosis")
- Every changed window costs ~12 synchronous AX IPC calls (pre-read, 2 settable checks,
  2 writes, verify read) on one serial queue; one slow app stalls every window.
- No timing data exists: we cannot tell which app or step is slow.
- `GioCore/Animation` (easing/lerp) is dead code: no frame player, windows jump.
- Real windows cannot be animated smoothly through AX (each frame is a cross-process
  call the target app answers asynchronously); Niri gets this for free as a compositor.

## Why
User (2026-09-29): "el scroll se ve feo y no fluido, queremos llegar a como se ve niri".
Phase 1 (window-coverage) live-passed; user approved moving to performance + animation.

## Scope (authorized)
Reflow performance and scroll/focus animation. Out of scope: unified desktop app (phase 3).

## Constraints
- Only `WindowReconciler` writes windows; animation never mutates logical state.
- Pure logic in GioCore with XCTest; GioDesktop/GioMacOS wiring stays thin.
- Conventional Commits, NO Co-Authored-By. Push/PR not authorized. Quote trailing-space path.

## Tasks
- [x] MO-01 — Reflow timing instrumentation: per-reflow total ms, per-window write ms and
  AX call count, slowest app; debug logs (ids/app names only) + a summary line.
- [x] MO-02 — Lean writes: drop the pre-write read and settable checks (use TileabilityCache),
  write position-only when size is unchanged, verify without blocking the next window.
- [x] MO-03 — Concurrent per-app writes: one serial lane per pid, lanes run in parallel,
  reflow completes when all lanes finish; a hung app cannot stall the others (timeout).
- [x] MO-04 — AX-driven animation spike (user decision 2026-09-29: "Probar AX primero"):
  animate only windows entering/leaving/moving on screen (typically 2-4) frame-by-frame via
  the reconciler using `GioCore/Animation` easing, cancellable/retargetable on new input,
  parked targets applied at the end; measure achieved fps per app with MO-01 timing.
  Fallback if too choppy: ScreenCaptureKit snapshot overlay (needs Screen Recording).
  DONE `55c48b8` (planMotion + [animations] config, default enabled, 200ms) + `f4acd90` (MotionPlayer, 120Hz DispatchSourceTimer on session queue, per-pid frame drop, retarget from physicalFrames, final exact reflow, `anim done` log). RED -> GREEN, 410 executed 0 failures (parent spot-check). LIVE PENDING: fps per app. Review: UNAVAILABLE.

Evidence MO-01..03 (route: one delegated writer): `0faf687` timing (`reflow timing total=`,
`reflow slow window=`), `7991966` lean writes (AX calls per moved window ~10 -> 6 both /
4 position-or-size / 3 parked, from asserted op sequences), `07a871a` per-pid concurrent
lanes, progress timeout 0.25s + AXUIElementSetMessagingTimeout 0.25s. 380 executed 0 failures
(parent ran twice, no flakes); signed build OK. No live baseline was captured before these
commits (gap). Risk: 0.25s messaging timeout also applies to discovery reads on slow apps.
Review: UNAVAILABLE.

## Acceptance criteria
- MO-01 numbers recorded before/after MO-02/MO-03 on the user's machine.
- A focus move with ~10 windows applies visibly faster than baseline (measured).
- `swift test` green; signed Gio build OK; `git diff --check` clean.

## Applicable checks
- TDD: STRICT ON (user global CLAUDE.md). Runner `swift test` (XCTest).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: RDD on by default but `gentle-ai review assess` fails on the trailing-space
  path; user chose continue without reporting (2026-09-29) -> record UNAVAILABLE.

## Delivery
Strategy `ask-on-risk`; one work-unit commit per task on `feat/gio-niri-rewrite`.

## Routes
- MO-01..MO-03: one delegated writer (reconciler + actuator + SessionHost + tests).

## Progress
- 2026-09-29: document created. Next: MO-01..MO-03; ask user about MO-04 approach.
- 2026-09-29: user chose AX-driven animation first (snapshot overlay as fallback). MO-04 starts after MO-01..MO-03 (depends on lanes + timing).
- 2026-09-29: MO-01..MO-03 done. Next: user live timing sample, then MO-04.
- 2026-09-29: live timing (25 reflows, 9 windows): total 2-12ms, axCalls 19-26, 0 lane timeouts; one Slack write hit 250ms, Xcode 42ms once. User still sees 2-by-2 jumps: expected, no animation yet. Perceived lag likely app repaint, unmeasured. AX animation budget confirmed feasible. Starting MO-04 (route: delegated writer).
- 2026-09-29: MO-04 done. Next: user live evaluation via `anim done` lines; decide keep AX vs snapshot fallback.
- 2026-09-29: LIVE PASS: 20 `anim done` samples, 25 frames/200ms (~125fps our side), dropped 0 (max 2, Chrome). Keep AX animation; snapshot fallback not needed. Feature closed; next work in odd/tasks/niri-controls.md.
