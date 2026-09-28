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
- [ ] RW-02 — §7 Phase 1 Window Registry: `WindowID`/`ManagedWindow`/`WindowMode`, register/remove/find/update, managed-vs-ignored, stale handling + tests. Route: delegated writer.
- [ ] RW-03 — §8 Phase 2 Workspace State: pure `Workspace`/`Column` model, zero macOS imports. Route: delegated writer.
- [ ] RW-04 — §9 Phase 3 Scrollable Layout Engine: `LayoutEngine.calculate(workspace:viewport:) -> LayoutResult`, column-strip model (NO BSP), mandatory layout tests. Route: delegated writer.
- [ ] RW-05 — §10 Phase 4 Viewport: `Viewport` + `ensureVisible`, clamped offsets. Route: inline or delegated by size.
- [ ] RW-06 — §11 Phase 5 Focus (focus-left/right/up/down, NO-OP on missing target, Alt+HJKL first). Route: inline or delegated by size.
- [ ] RW-07 — §12+§13 Phases 6+7 Move + Resize (move L/R/U/D; resize-width/height + reset; resize mode). Route: delegated writer.
- [ ] RW-08 — §14 Phase 8 Window Reconciler: sole physical writer, diff position/size/focus/mode, apply only deltas. Route: delegated writer.
- [ ] RW-09 — §29/§35 Milestone 0.1 Core assembly: POC -> Registry -> State -> Layout -> Viewport -> Focus -> Reconciler -> macOS, VSCode/Terminal/Chrome scenario, full Core suite green. Route: delegated writer + independent verifier.

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

## Verification evidence
- `git branch --list archive/*` -> `archive/pre-rewrite-niri-plan` present.
- `git log --oneline -3 archive/pre-rewrite-niri-plan` -> e126424 / fc4bc11 / 3513e3f (matches HEAD).
