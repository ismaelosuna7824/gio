# Niri controls: column sizing and real workspaces

## Objective
Close the most visible gaps with Niri: resize/expand columns and return to normal
tiling from the keyboard, real fullscreen, centering, stacking windows in a column,
and workspaces that actually hide the inactive ones with an animated switch.

## Problem (code check 2026-09-29)
- `HotkeyAction` only has focus/move/workspace/moveToWorkspace/toggleFloating/fullscreen;
  `GioCore/Resize` (width adjust/reset, height factor) has no hotkey or action.
- `fullscreen` and `toggleFloating` ship unbound; `toggleFullscreen` only flips registry
  state, it never resizes the window.
- No maximize-column, width presets, center-column or consume/expel.
- Workspace switch (`session.manager.switchTo`) only lays out the new workspace; windows
  of the previous workspace keep their frames and stay visible.

## Why
User (2026-09-29): "en niri se pueden expandir las ventanas o regresar al tiling normal,
ademas no se como funciona los workspaces". Chose recommended order: column controls
first, then workspaces.

## Scope (authorized)
Column controls (NC-01..NC-05) then workspace hiding + animated switch (NC-06, NC-07).
Not yet authorized: dynamic vertical Niri workspaces, overview, trackpad scrolling.

## Constraints
- Actions are pure Core use cases on Workspace/registry; hotkeys map to actions only;
  only WindowReconciler writes; all motion goes through MO-04 animation.
- Default bindings use Alt (Niri Mod); every binding overridable in `config.toml`,
  documented in `defaultConfigTemplate`.
- Conventional Commits, NO Co-Authored-By. Push/PR not authorized. Quote trailing-space path.

## Tasks
- [x] NC-01 (`be48f8b`) — Width presets + step resize: Alt+R cycles `preset-column-widths`
  (default 1/3, 1/2, 2/3, Niri proportion semantics), Alt+Minus / Alt+Equal = -/+10%,
  config key parsed/validated.
- [x] NC-02 (`0c4d429`) — Maximize column toggle (Alt+F): focused column takes full width; toggling
  again restores the previous width.
- [x] NC-03 (`fa807f9`) — Real fullscreen toggle (Alt+Shift+F): focused window fills the display
  frame (no native macOS fullscreen Space), others park; toggle restores its column.
- [x] NC-04 (`77f9ca1`) — Center column (Alt+C): viewport centers the focused column.
- [x] NC-05 (`f5c874d`) — Consume/expel (Alt+BracketLeft / Alt+BracketRight): pull the focused window
  into the neighbouring column / push it out into its own new column.
- [ ] NC-06 — Hide inactive workspaces: windows of non-active workspaces park off-screen
  (corner/edge, display-aware), restore on switch back and on Gio exit.
- [ ] NC-07 — Animated workspace switch using the MO-04 player.

Evidence NC-01..05 (route: one delegated writer): ColumnWidthSpec (standard/proportion/points)
resolved per display; savedWidthSpec for maximize; FullscreenBook + full-display frame below
menu bar, others parked in place; center survives reveal; consume keeps height weight.
Bindings: Alt+R, Alt+Minus/Equal, Alt+F, Alt+Shift+F, Alt+Shift+Space (floating), Alt+C,
Alt+BracketLeft/Right. RED (compile) -> GREEN each task; 455 executed 0 failures (parent
spot-check); signed build OK. Gaps: no CLI/IPC equivalents; LIVE PENDING. Review: UNAVAILABLE.

## Acceptance criteria
- Each binding works live and animates; toggles are reversible without drift.
- Switching workspaces shows only the active workspace's windows.
- `swift test` green; signed Gio build OK; `git diff --check` clean.

## Applicable checks
- TDD: STRICT ON (user global CLAUDE.md). Runner `swift test` (XCTest).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: UNAVAILABLE (gentle-ai trims trailing-space path; user chose continue without reporting).

## Delivery
Strategy `ask-on-risk`; one work-unit commit per task on `feat/gio-niri-rewrite`.

## Routes
- NC-01..NC-05: one delegated writer (Core actions + hotkeys + config + SessionHost + tests).
- NC-06..NC-07: one delegated writer after NC-05 lands.

## Progress
- 2026-09-29: document created (after MO-04 live pass: 25 frames/200ms, dropped ~0). Next: NC-01..NC-05.
- 2026-09-29: NC-01..NC-05 done. Next: NC-06..NC-07 (route: delegated writer).
