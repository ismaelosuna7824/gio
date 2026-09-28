# Gio Niri-plan rewrite (Gio, not MyNiri)

## Objective
Rebuild Gio as a Niri-style scrollable tiling WM for macOS, following ALL 37 sections
of the plan doc (`/Users/ismaelosuna/Downloads/Plan de implementación — MyNiri.md`)
with every MyNiri name replaced by Gio. Full scope: Phases 0-22 plus milestones,
testing, logging, agent rules, DoD and final Omarchy-like desktop experience.

## Problem
Current Gio tiles with a balanced binary-split layout (`TileLayout.plan`), a
`NativeTilingCoordinator` with transactional AX rollback, and an AX/CG eligibility
heuristic (`SpaceWindowEligibility`, `SpaceWindowSnapshot`). That works as a prototype
but does not match the plan's architecture: pure `GioCore` state + scrollable column
`LayoutEngine` + single `WindowReconciler`, with macOS isolated in adapters.

## Why rewrite from Phase 0 (user decision 2026-09-28)
User chose "Rewrite desde Fase 0": freeze current work in a branch and rebuild
phases in the plan's exact order instead of incrementally refactoring the binary-split
coordinator. Current HEAD is frozen at `archive/pre-rewrite-niri-plan` (e126424).
User then noted the doc has ~37 points: this feature tracks ALL of them, not just
the 0.1-alpha core. Plan §36 stays an ordering gate (core stable before desktop
chrome), never a scope cut.

## Plan coverage map (37 sections -> where each lives)
- §1 Objetivo -> this Objective. §2 Principios (10) -> Constraints. §3 Stack ->
  Constraints. §4 Arquitectura + §37 Resultado final -> Target structure (vision).
  §5 Estructura -> Target structure. §29 Milestones -> RW-09/RW-24/RW-25/RW-26/RW-27.
  §30 Testing -> every task's acceptance + RW-27. §31 Logging -> RW-28 (starts early,
  ships as `gio logs`). §32 Reglas agente -> Constraints (working agreement).
  §33 DoD (18 steps) -> Acceptance criteria. §34 Orden exacto -> task order below
  (single phase at a time). §35 0.1-alpha -> RW-09. §36 Restricción -> ordering gate.

## Constraints (plan §2, §3, §32 condensed)
- Swift, SPM, AppKit, SwiftUI (aux UI only), AXUIElement/AXObserver, CoreGraphics,
  CGEvent/Carbon hotkeys, Swift Testing, TOML config. SIP stays enabled, public APIs only.
- State is source of truth; `LayoutEngine` knows no macOS; adapters isolate
  Accessibility/displays/hotkeys; focus/layout/move are independent concepts.
- Only `WindowReconciler` may physically move windows. Logic changes go State ->
  Layout -> Reconciler -> macOS; never hotkey -> AX directly.
- One phase at a time; next starts only when current compiles + has tests. No UI
  before a working WM; no animations before stable layout; no launcher/bar/themes
  before the WM MVP. Small descriptive commits; never break existing features.
- Prefer events over polling. Log from early phases. Document macOS limitations and
  per-app Accessibility quirks; no hidden AX errors, no undocumented app workarounds.
- Current code is REFERENCE ONLY: `TileLayout` (binary split) informs but does not
  satisfy the scrollable column engine; `AXWindowBridge` / `SpaceWindowEligibility` /
  `NativeTilingCoordinator` inform the later reconciler/recovery work.
- Branch `feat/virtual-workspaces` stays as-is; rewrite work happens per-task with
  work-unit commits. Push/PR/merge NOT authorized (carried over). Untracked
  `.build/`, `.swiftpm/`, `.DS_Store`, `.gitignore`, `xcworkspace/` stay uncommitted.
- NOTE: repo directory on disk has a trailing space (`gio `); tooling must quote it.

## Target structure (plan §5, MyNiri -> Gio renames applied)
- Sources/GioCore/{State,Window,Workspace,Display,Layout,Focus,Reconciliation,Events}
- Sources/GioMacOS/{Accessibility,WindowServer,Hotkeys,Displays}
- Sources/GioCLI, Sources/GioApp/{MenuBar,Launcher,Preferences}
- Tests/{LayoutTests,WorkspaceTests,FocusTests,ReconciliationTests}
- Current `Sources/GioCore|GioMac|GioApp` + `Tests/GioCoreTests|GioMacTests` remain
  untouched until each rewrite task explicitly replaces a piece; deletion only via
  explicit user-authorized work unit.

## Tasks — Core 0.1 (plan §6-§14, §35)
- [x] RW-00 — Freeze current work at `archive/pre-rewrite-niri-plan` (e126424). Route: inline (git state op). Evidence: branch listed, log matches HEAD.
- [x] RW-01 — §6 Phase 0 Accessibility POC: `gio-poc list-windows|focus|move|resize` + events (created/destroyed/focus/moved/resized/activated). DoD §6. Route: inline slices, DONE inline 2026-09-28 (delegated writer unavailable).
- [x] RW-02 — §7 Phase 1 Window Registry: `WindowID`/`ManagedWindow`/`WindowMode`, register/remove/find/update, managed-vs-ignored, stale handling + tests. Route: inline (delegated writer unavailable); legacy string identity renamed to LegacyWindowID (pure rename, behavior unchanged).
- [x] RW-03 — §8 Phase 2 Workspace State: pure `Workspace`/`Column` model, zero macOS imports. Route: inline (delegated writer unavailable); DONE `263d79c`, 5 state tests green, 0 warnings.
- [x] RW-04 — §9 Phase 3 Scrollable Layout Engine: `LayoutEngine.calculate(workspace:viewport:) -> LayoutResult`, column-strip model (NO BSP), mandatory layout tests. Route: inline (delegated writer unavailable); DONE `2da99bf`, 13 engine tests green (one test-math fix, engine was right), full suite 0 failures.
- [x] RW-05 — §10 Phase 4 Viewport: `Viewport` + `ensureVisible`, clamped offsets. Route: inline; DONE with RW-06 in `18315f1`, 12 viewport+focus tests green, full suite 0 failures.
- [x] RW-06 — §11 Phase 5 Focus (focus-left/right/up/down, NO-OP on missing target, Alt+HJKL first). Route: inline; DONE with RW-05 in `18315f1`.
- [x] RW-07 — §12+§13 Phases 6+7 Move + Resize (move L/R/U/D; resize-width/height + reset; resize mode). Route: inline (delegated writer unavailable); DONE `25656ad`, 15 move/resize tests green, full suite 0 failures. Resize mode (Alt+R) is a Phase 13 hotkey concern.
- [x] RW-08 — §14 Phase 8 Window Reconciler: sole physical writer, diff position/size/focus/mode, apply only deltas. Route: inline (delegated writer unavailable); DONE `9eaa4c4`, 6 reconciler tests green, full suite 0 failures. GioMacOS now depends on GioCore (adapters → core).
- [x] RW-09 — §29/§35 Milestone 0.1 Core assembly: POC -> Registry -> State -> Layout -> Viewport -> Focus -> Reconciler -> macOS, VSCode/Terminal/Chrome scenario, full Core suite green. Route: inline (delegated writer unavailable); DONE `4482d28` (`gio-poc tile` one-shot on main visibleFrame), 5 assembly tests green, full suite 0 failures. Live user-operated retest pending — hardcoded hotkeys deferred to RW-14.

## Tasks — WM 0.2 (plan §15-§18)
- [ ] RW-10 — §15 Phase 9 Workspaces: `WorkspaceManager`, 1-9 + Alt+N / Alt+Shift+N, per-workspace columns/focus/viewport. Route: delegated writer.
- [ ] RW-11 — §16 Phase 10 Multi-monitor: `DisplayState`, connect/disconnect/resolution/scale handling, independent workspace/viewport/focus per display. Route: delegated writer.
- [ ] RW-12 — §17 Phase 11 Floating + Fullscreen: floating outside layout, state-preserving fullscreen. Route: inline or delegated by size.
- [ ] RW-13 — §18 Phase 12 Window Rules: TOML `[[window-rules]]`, created -> rules -> workspace/mode -> layout pipeline. Route: delegated writer.

## Tasks — DX 0.3 (plan §19-§23)
- [ ] RW-14 — §19 Phase 13 Hotkey system: keyboard event -> `Action` only, logic lives in Core use cases. Route: delegated writer.
- [ ] RW-15 — §20 Phase 14 Config: `~/.config/gio/config.toml`, parser/validation/defaults/errors/reload, invalid config never breaks the WM. Route: delegated writer.
- [ ] RW-16 — §21 Phase 15 CLI: `gio reload|restart|list-windows|list-workspaces|focus|move|workspace|layout info`, single-instance guard. Route: delegated writer.
- [ ] RW-17 — §22 Phase 16 IPC: CLI <-> Gio (focus/move/resize/workspace/reload/query/layout), JSON responses for scripts/launcher/bar. Route: delegated writer.
- [ ] RW-18 — §23 Phase 17 Recovery: dead apps, vanished/late windows, display loss, invalid config, lost AX permission; stale-window purge pipeline. Route: delegated writer.

## Tasks — UI 0.4 (plan §24-§26)
- [ ] RW-19 — §24 Phase 18 Animations (only after stable layout): move/resize/scroll/workspace/focus; animations never touch logical state. Route: delegated writer.
- [ ] RW-20 — §25 Phase 19 Menu Bar app: workspaces, window count, WM state, reload/preferences/quit. Route: delegated writer.
- [ ] RW-21 — §26 Phase 20 Launcher: search/open/run/workspace-switch/Gio-action via IPC (never direct Core access). Route: delegated writer.

## Tasks — 1.0 desktop (plan §27-§29, §33)
- [ ] RW-22 — §27 Phase 21 Themes: `~/.config/gio/themes/` (colors/gaps/borders/launcher/bar/wallpaper/typography). Route: delegated writer.
- [ ] RW-23 — §28 Phase 22 Omarchy-like: `gio setup|update|doctor|uninstall` (+ autostart); doctor covers AX permission/config/version/process/IPC/displays/errors. Route: delegated writer.
- [ ] RW-24 — §29 Milestone 0.2 verification (workspaces/multi-monitor/floating/fullscreen/rules). Route: verifier.
- [ ] RW-25 — §29 Milestone 0.3 verification (hotkeys/TOML/CLI/IPC/recovery). Route: verifier.
- [ ] RW-26 — §29 Milestone 0.4 verification (animations/menu bar/launcher). Route: verifier.
- [ ] RW-27 — §29 Milestone 1.0 + §30 + §33: full 18-step DoD flow, LayoutEngine coverage (insert/delete/focus/move/resize/viewport/boundaries/columns/windows/switching), Core-without-GUI integration chain (event -> registry -> state -> layout -> reconciler). Route: verifier.

## Tasks — transversal (plan §31)
- [ ] RW-28 — §31 Logging: error/warn/info/debug/trace from early phases; `gio logs [--level]`; never log window titles via Screen Recording. Starts at RW-01, ships here. Route: inline slices.

## Acceptance criteria (§33 DoD + §30)
- `swift test` green for every completed RW task; each task closes only on observed test + `git diff --check` evidence.
- Final DoD flow demonstrable: open VSCode/Terminal/Chrome -> detect -> columns -> H/J/K/L nav -> auto-scroll -> focused stays visible -> move -> resize -> close/insert handling -> workspace switch -> two-monitor independence -> floating aside -> managed recovery -> `gio doctor` -> all Core tests pass.
- Live AX validation uses signed `Gio.xcodeproj` Gio scheme (never bare `swift run`); results recorded, never inferred from mocks.
- §36 respected as order: desktop chrome (RW-19..RW-23) only after core RW-01..RW-08 stable with tests.

## Applicable checks
- TDD mode: OFF (source: odd/tasks/automatic-tiling.md, no configured TDD mode). Runner: `swift test`.
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: native RDD switch is user-owned; no review claimed unless user enables it.

## Delivery
- Strategy: `ask-on-risk` (default). Forecast is multi-thousand lines across 29 tasks: one work-unit commit per task minimum, slice further if a task nears ~400 authored lines; if a cohesive slice exceeds budget, ask for `size:exception` vs split before proceeding. Chain strategy undecided (only if chaining needed later).

## Progress
- 2026-09-28: RW-00 done (freeze branch created). Gap mapping done inline (delegated `explore` unavailable: provider free-tier restriction). Scope expanded to all 37 plan sections per user note (was: 0.1-alpha only). Next: RW-01 Phase 0 POC.
- 2026-09-28: RW-01 done, commit `f05d0f9` (892 insertions, new standalone tool; exceeds ~400 advisory — cohesive new target, no size-only split). Follow-up promotion `1600e4d`: logic lives in final `GioMacOS` (SystemWindow/discover/actions/events), `gio-poc` is a thin CLI; tests split into `GioMacOSTests` (4) + `GioPOCTests` (6), full suite 0 failures. `swift build --target GioPOC` ok; `swift test` 0 failures (9 new GioPOCTests, existing suites green); `git diff --check` clean. New files: Sources/GioPOC (POCWindow/POCCommand/POCDiscovery/POCActions/POCEvents/main), Tests/GioPOCTests, Package.swift targets. Live AX retest pending (signed binary + user Accessibility grant). Next: RW-02 Window Registry.
- 2026-09-28: RW-02 done, commit `546c523`. New `GioCore/Window/` (WindowID pid+elementID with Comparable ordering, ManagedWindow, WindowMode, WindowRegistry with register/update/remove/find/ignore/removeStale); 9 registry tests green, full suite 0 failures, `git diff --check` clean. elementID is adapter-assigned session identity (no stable public OS window number exists). Next: RW-03 Workspace State.
- 2026-09-28: RW-03 done, commit `263d79c`. New `GioCore/Workspace/` (WorkspaceID/Workspace/ColumnID/Column, nil-safe focus accessors, value semantics); 5 state tests green, full suite 0 failures, `git diff --check` clean. Next: RW-04 Scrollable Layout Engine.
- 2026-09-28: RW-04 done, commit `2da99bf`. New `GioCore/Layout/` (LayoutConfig/LayoutResult/LayoutEngine protocol/ScrollableLayoutEngine, absolute frames, clamped offsets, insertion-stable); 13 engine tests green, full suite 0 failures, `git diff --check` clean. Next: RW-05 Viewport.
- 2026-09-28: RW-05+RW-06 done, commit `18315f1`. New `GioCore/Viewport/` (clamped offsets, minimal-scroll ensureVisible, wide-range pins to start) + `GioCore/Focus/` (pure H/L/J/K moves, NO-OP on missing, per-column memory); 12 tests green, full suite 0 failures, `git diff --check` clean. Focus→ensureVisible→Layout→Reconciler composition lands in RW-09. Next: RW-07 Move + Resize.
- 2026-09-28: RW-07 done, commit `25656ad`. New `GioCore/Move/` (Niri-style edge growth, emptied-column removal, focus follows, weights travel) + `GioCore/Resize/` (width adjust/reset, height factor/reset); Column gains heightWeights, engine distributes proportionally (equal defaults unchanged); 15 tests green, full suite 0 failures, `git diff --check` clean. Next: RW-08 Window Reconciler.
- 2026-09-28: RW-08 done, commit `9eaa4c4`. New `GioCore/Reconciliation/` (WindowActuator protocol, ReconcileReport, WindowReconciler with minimal writes/tolerance/vanished-failed recording/focus-last) + `AXWindowActuator` (growth-aware order, readback, pid-reuse guard, shared focus primitive); 6 tests green, full suite 0 failures, `git diff --check` clean. Next: RW-09 milestone 0.1-alpha assembly.
- 2026-09-28: RW-09 done, commit `4482d28`. New `GioMacOS/Assembly/` (runTileReflow: enumerate → tileable probe → register → one-column-per-window workspace → layout on main visibleFrame → reconcile, focus never stolen, typed report) + `axIsTileable` probe + `tile` verb; 5 assembly tests green, full suite 0 failures, `git diff --check` clean. MILESTONE 0.1 CODE-COMPLETE pending live validation. One-click Xcode entry: `Gio.xcworkspace` (`7e45f7f`) with shared `gio-poc-list` / `gio-poc-tile` schemes (preset args, verified build). GioLab UI harness (`0adc832`): SwiftUI window with Request Access/List/Tile buttons reusing GioMacOS; permission failures now pop the system dialog. LIVE: user ran GioLab, access granted, `list-windows` returned 11 windows skipped=0 (Finder/Ghostty/Chrome/Xcode/Slack/OrbStack/Code/Figma/Settings). `tile` retest still pending.
- 2026-09-28: live `tile` failed 12/12 uniformly with `frameMismatch requested=(8,8,900,1114) actual=(8,39,900,1114)` — macOS accepted x+size but clamped y 8→39, so the viewport's usable-area map is wrong (Dock band?). Added display geometry readout (`be89345`); awaiting re-run with screen numbers.
- 2026-09-28: geometry revealed the real bug — mixed coordinate systems (NSScreen bottom-left vs AX top-left). Fix `614ec32`: AXVerticalFlip converts at adapter boundary (discovery ingest + actuator read/write), callers pass full display height. 4 flip tests green, full suite 0 failures. Xcode's own scheme normalization left unstaged (args intact). Awaiting tile re-run. Next: RW-10 Workspaces (0.2) or user live retest.

## Verification evidence
- `git branch --list archive/*` -> `archive/pre-rewrite-niri-plan` present.
- `git log --oneline -3 archive/pre-rewrite-niri-plan` -> e126424 / fc4bc11 / 3513e3f (matches HEAD).
