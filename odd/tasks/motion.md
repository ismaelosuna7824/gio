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
- [ ] MO-01 — Reflow timing instrumentation: per-reflow total ms, per-window write ms and
  AX call count, slowest app; debug logs (ids/app names only) + a summary line.
- [ ] MO-02 — Lean writes: drop the pre-write read and settable checks (use TileabilityCache),
  write position-only when size is unchanged, verify without blocking the next window.
- [ ] MO-03 — Concurrent per-app writes: one serial lane per pid, lanes run in parallel,
  reflow completes when all lanes finish; a hung app cannot stall the others (timeout).
- [ ] MO-04 — Animation approach (pending user decision: AX-driven vs snapshot overlay).

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
