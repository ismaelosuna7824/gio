# Performance audit: idle ~0%, cheaper frames, adaptive size animation

## Objective
Cut Gio's CPU/energy (Xcode showed "Energy Impact: Very High") to near zero at idle and much
lower during motion, and make maximize/resize animations grow smoothly where the app supports it.

## Problem (read-only audit 2026-09-29, ranked; evidence file:line in the audit summary)
1. `GioLog.record` reopens the log file per line (~6 syscalls + new ISO8601DateFormatter), no
   level gate, interpolation always built; log never rotated (1.2 MB, 7.9k DEBUG lines).
2. Motion timer fixed at 120 Hz regardless of display refresh.
3. `NSRunningApplication(...).localizedName` per window write per frame (timing only).
4. Per-frame closure/worker/DispatchGroup per pid; AX call counter lock per AX call; unbounded
   timing array.
5. Final pass reads AX frames of every window incl. parked ones Gio placed itself.
6. Render verification: `CGWindowListCopyWindowInfo(.optionAll)` + AX reads of all targets per settle.
7. Sub-point/no-op writes (tolerance 0.5 vs 1 mismatch); spring tail ticks at 120 Hz.
8. Focus ring published + dictionary merges every motion tick.
9. Idle polling: MenuBar IPC status every 3s (socket per poll); tap watchdog every 2s.
10. `id(matching:)` linear CFEqual scan per AX moved/resized event, before the echo gate.
11. Full-resync path (all-app AX enumeration) still reachable on activation when tap refused.
12. UI tickers: LogsView re-reads 256 KB + renders 1000 rows every 1s; other views 2-3s.
13. Debug log writes on hotkey/focus hot paths (covered by 1).
14. Inactive-workspace parking re-planned every reflow; hidden windows iterated in reconcile.
Animation: FI-03 `motionFrame` defers every grow to the final pass, so maximize looks cut
(neighbours retreat, then the window jumps). Per-app timing exists but never feeds the planner.

## Why
User (2026-09-29): focus on code before new features; better performance and animation
control; maximize should not look cut; "consumir mucho menos".

## Scope (authorized)
PA-01..PA-06 below. No new user-facing features beyond config for log level / adaptive grow.

## Constraints
Pure logic in GioCore with XCTest; only WindowReconciler writes; Gio never manages its own pid;
main thread never waits on the session queue. Conventional Commits, NO Co-Authored-By. Push to
origin feat/gio-niri-rewrite after verified batches; no PR. Quote trailing-space path.

## Tasks
- [ ] PA-01 — Logging: one persistent handle, static formatter, `@autoclosure` + min level
  (default info), background batched writes, rotation ~1 MB, drop routine debug noise. (#1, #13)
- [ ] PA-02 — Idle ~0%: MenuBar refresh on menuWillOpen/push instead of 3s IPC poll; watchdog
  relaxed (30s, large leeway); UI tickers only while the main window is visible; LogsView tails
  from last offset, no textSelection on 1000 rows. (#9, #12)
- [ ] PA-03 — Frame pacing: timer interval from the display's maximumFramesPerSecond; whole-point
  rounding + unified tolerance 1; spring ends under 1pt residual; no per-frame appName lookup;
  timings aggregated in place; AX call counting debug-only. (#2, #3, #4, #7)
- [ ] PA-04 — Lean settle: trust `physicalFrames` for windows Gio placed (skip AX reads for parked /
  unchanged), render verification on-screen-only snapshot for visible targets, ring/echo/physical
  updates only for changed windows, cached inactive-workspace plan, hash-indexed handle lookup +
  echo check before resolution. (#5, #6, #8, #10, #14)
- [ ] PA-05 — Per-pid persistent write lanes (no per-frame closure/worker allocation). (#4)
- [ ] PA-06 — Adaptive size animation: per-app EWMA of write cost/drops/clamps; fast apps grow
  during flight (maximize grows while neighbours retreat, no overlap along the path); slow apps keep
  the FI-03 final-pass grow.

## Acceptance criteria
- Idle: no periodic wakeups from Gio except event delivery (verify with log + Activity Monitor).
- Motion: fewer AX calls per animation (reported in `anim done`/timing) and frame rate matches display.
- Maximize on a fast app grows smoothly with no overlap; slow apps unchanged.
- All 5 bundles green; signed build OK; docs updated.

## Applicable checks
- TDD: STRICT ON. Runner `swift test` (read all 5 "Executed" lines).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: UNAVAILABLE (gentle-ai trailing-space path defect; user chose continue).

## Routes
Read-only audit: delegated Explore (done). PA-01..PA-06: delegated writers, sequential.

## Progress
- 2026-09-29: audit done, document created. Next: user go-ahead, then PA-01.
