# Window coverage (phase 1 of live-issues plan)

## Objective
Every normal window on the active display gets managed by Gio: tiled when it can be
resized, visibly tracked as floating (with a reason) when it cannot. No window stays
silently untiled, and apps/windows opened after startup join the layout immediately.

## Problem (diagnosis 2026-09-29, engram "Gio live issues diagnosis")
- `WindowDiscovery.swift:59,116-128` accepts only `AXStandardWindow`; Electron/Java/Qt
  windows with nonstandard/empty subroles and dialogs are dropped uncounted.
- Non-resizable windows fail `axIsTileable` and are omitted from `modes`
  (`SessionHost.swift:255-266`) with no trace.
- No `NSWorkspace.didLaunchApplication` observer: new apps join only when activated,
  via a 0.3s debounced full rescan that tears down every observer.
- Windows created after the observer was built get no per-window destroyed/moved
  notifications; closed windows linger until their process dies.
- Windows minimized at startup are skipped and never picked up; rules are evaluated
  only at registration.

## Why
User report: "cuando hace el tiling no lo hace para todas las ventanas abiertas,
algunas aun se quedan flotando". User approved phase 1 first (2026-09-29).

## Scope (authorized)
Window admission, observation and registration only. Out of scope: animation/perf
(phase 2/4), unified desktop app (phase 3). Other Spaces stay a documented limit.

## Constraints
- Pure decision logic lives in GioCore/GioMacOS with Swift Testing coverage; GioDesktop
  (no test target) only wires it. Only `WindowReconciler` moves windows.
- Commits: Conventional Commits, NO Co-Authored-By / AI attribution (user rule).
- Directory has a trailing space; quote paths.

## Tasks
- [x] WC-01 — Admission classifier: pure `WindowAdmission` (role/subrole/settable/
  fullscreen/minimized -> tile | float(reason) | ignore(reason)); standard + unknown
  resizable subroles tile, dialogs/floating/non-resizable float, sheets/popovers ignore.
  Discovery reports every exclusion with a reason.
  DONE `6cfa1db`: 13 tests (RED 11/13 on stub -> GREEN), swift test 210 executed 0 failures, signed Gio build OK, diff --check clean. Added `.suspend(fullscreen|minimized)` outcome; discovery result gains `floating`/`ignored`. Review: assess UNAVAILABLE (gentle-ai trims trailing-space repo path: lstat .../gio not found) -> treated as due, pending user decision.
- [x] WC-02 — Floating is managed, not omitted: non-tileable windows register as
  floating with a reason; tileability cached per window (re-probed on resize/
  attribute events, not every reflow); `list-windows`/status expose mode + reason.
  DONE `d763b75`: 15 tests (RED compile-fail -> GREEN), 225 executed 0 failures (parent spot-check re-ran), signed build OK. Fixed latent bug: probe-failing windows were missing from `modes` and thus laid out anyway. Gap: cache is invalidateAll on every resyncAndReflow (every AX event) — refine per-window in WC-04; ignored/suspended not exposed in status. Review: UNAVAILABLE (gentle-ai trailing-space path defect; user chose continue without reporting).
- [x] WC-03 — Incremental app observation: launch/terminate observers attach/detach one
  pid's AX observer and register/reap its windows without a full teardown.
  DONE `e9c8066`: pure ObservationBook (10 tests RED compile-fail -> GREEN), 235 executed 0 failures, signed build OK. Fixed latent bug: rebuilt observers were attached to the session queue's run loop (never ran); now always main run loop. Review: UNAVAILABLE (gentle-ai path defect, user chose continue).
- [x] WC-04 — Per-window observers for windows created after startup (destroyed/moved/
  resized/minimized/deminimized); destroyed windows leave the layout immediately.
  DONE `695ac17`: typed events with pid+element, WindowEventPolicy/WriteEchoGate (20 tests RED -> GREEN), 255 executed 0 failures (parent spot-check), signed build OK. Tileability invalidateAll only on permission regain. AX wiring compiled only, LIVE PENDING. Review: UNAVAILABLE.
- [x] WC-05 — Minimize lifecycle: minimized windows stay registered but out of layout;
  deminimize re-inserts; rules re-evaluated on config reload. Added 2026-09-29 (WC-04 gap):
  full rescans also purge registered windows of a scanned pid that no longer appear
  (fallback when destroyed-element CFEqual matching fails).
  DONE `b7fb956`: isMinimized flag, pure minimize/restore, reevaluateRules, vanishedWindowIDs gated by completePIDs (29 tests RED compile-fail -> GREEN), 284 executed 0 failures (parent spot-check), signed build OK. Gaps: no workspace reassignment on reload; manual tile vs float rule not tracked; deminimize doesn't switch workspace; a registered window newly classified `ignore` gets purged. Review: UNAVAILABLE.
- [x] WC-06 — Park off-viewport columns (added 2026-09-29 from live run, user approved):
  live log showed each reflow moved only the 2-3 visible windows; `splitVisibleFrames`
  drops off-viewport frames, so those windows keep stale frames and stack behind the
  visible columns. Park them nearly fully off-screen (1px visible) on the side they
  belong to (left columns -> left edge, right columns -> right edge), AeroSpace-style,
  avoiding edges shared with another display (fallback bottom-right corner); parked
  frames verified with tolerance, never raised/focused.
  DONE `3a30bbe`: pure planParking (full display frame, Cocoa coords), reconciler accepts clamped parked landing (<=40pt strip) then `already`; 18 tests RED -> GREEN, 302 executed 0 failures (parent spot-check), signed build OK. LIVE PENDING: does macOS accept the 1pt strip. Review: UNAVAILABLE.

## Acceptance criteria
- Opening a new app or window after Gio starts tiles it without switching apps.
- Closing a window reflows immediately.
- Fixed-size windows appear in status as floating with reason `notResizable`.
- `swift test` green; signed Gio scheme builds.

## Applicable checks
- TDD: STRICT ON (source: user global CLAUDE.md "Strict TDD Mode: enabled"; supersedes
  the older "OFF" note in gio-niri-rewrite.md). Runner: `swift test`.
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- `git diff --check`.
- Review: RDD on (default). After each work-unit commit run
  `gentle-ai review assess --cwd <repo> --agent claude-code --base-ref <boundary> --committed-only --json`.
  First boundary: `31d17c0`.

## Delivery
Strategy `ask-on-risk`. Forecast ~600-900 authored lines across 5 tasks; one work-unit
commit per task on `feat/gio-niri-rewrite`. Push/PR not authorized.

## Routes
- WC-01..WC-05: delegated writer (2+ non-trivial files per task: GioMacOS + GioDesktop + tests).

## Progress
- 2026-09-29: document created after diagnosis. Next: WC-01.
- 2026-09-29: WC-01 done `6cfa1db` (route: delegated writer). Test-count note: 247 was declared `func test` count at 31d17c0, now 260 declared; runner executes 210 (pre-existing gap, not a regression). Next: WC-02.
- 2026-09-29: WC-02 done `d763b75` (route: delegated writer). Next: WC-03.
- 2026-09-29: WC-03 `e9c8066` + WC-04 `695ac17` done (route: one delegated writer, shared files). Next: WC-05.
- 2026-09-29: WC-05 done `b7fb956` (route: delegated writer). PHASE 1 CODE-COMPLETE; LIVE PENDING: user run of signed Gio scheme (open app after start, close window, minimize/restore, Electron app tiles). Delivery: ~1.2k authored lines over 5 commits exceeds ~400 budget; chain strategy deferred because push/PR are not authorized. Next: live validation, then phase 2 (perf).
- 2026-09-29: live run (user screenshots + ~/.config/gio/gio.log): tiling works but off-viewport windows stay stacked behind (`reconcile applied=2..3` per focus move). Added WC-06. Route: delegated writer.
- 2026-09-29: WC-06 done `3a30bbe`. Next: user live retest.
