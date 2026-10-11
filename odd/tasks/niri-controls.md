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
- [x] NC-06 (`021c6bc`) — Hide inactive workspaces: windows of non-active workspaces park off-screen
  (corner/edge, display-aware), restore on switch back and on Gio exit.
- [x] NC-07 (`fba8058`) — Animated workspace switch using the MO-04 player.
- [ ] NC-08 (`e564c8d`) — Window heights in a stacked column: `switch-preset-window-height`
  (Alt+Shift+R) over new `layout.preset-window-heights` (default 1/3, 1/2, 2/3 of the usable
  height, same proportion/points rule as widths), `set-window-height-minus/plus`
  (Alt+Shift+Minus/Equal, ±10%), `reset-window-height` (Ctrl+Alt+R, equal shares); Settings >
  Layout > Window Height (same chips as the widths).
- [ ] NC-09 (`e564c8d`) — Column navigation: `focus-column-first/last` (Alt+Home/End),
  `move-column-to-first/last` (Ctrl+Alt+Home/End), `swap-window-left/right` (unbound).
- [ ] NC-10 (`e564c8d`) — `move-column-to-workspace N` (Ctrl+Alt+1..9) and
  `move-column-to-workspace-down/up` (Ctrl+Alt+U/I): the whole column, focus follows.
- [ ] NC-11 (`e564c8d`) — `focus-workspace-previous` (unbound; per-display history) and
  `move-workspace-down/up` (Ctrl+Alt+Shift+U/I; named workspaces refused and logged).
- [ ] NC-12 — More niri actions (user request 2026-10-11): `focus-window-or-workspace-down/up`
  (unbound; `WorkspaceManager.focusWindowOrWorkspaceDown/Up`: the window below/above in the
  column, else the workspace below/above; true only when the workspace changed),
  `switch-preset-column-width-back` (unbound: niri's Mod+Shift+R is Gio's window-height cycle),
  `expand-column-to-available-width` (Ctrl+Alt+F, niri Mod+Ctrl+F) and `center-visible-columns`
  (Ctrl+Alt+C, niri Mod+Ctrl+C) in `Layout/VisibleColumns.swift`. 75 default bindings.
  Decisions: "fully visible" = the column's content range inside the viewport within 0.5 pt; the
  expanded width is stored as a proportion (adapts across displays, like the 10% steps) and the
  view scrolls so the group starts at the left padding (fills padding to padding); expand is a
  NO-OP without room to grow; center-visible always includes the focused column (a column wider
  than the viewport is never fully visible). Or-workspace moves animate as a workspace switch
  (a move within the column does not scroll). Expand and preset-back grow the focused window
  (focused-grow); center-visible is a view scroll.

Evidence NC-01..05 (route: one delegated writer): ColumnWidthSpec (standard/proportion/points)
resolved per display; savedWidthSpec for maximize; FullscreenBook + full-display frame below
menu bar, others parked in place; center survives reveal; consume keeps height weight.
Bindings: Alt+R, Alt+Minus/Equal, Alt+F, Alt+Shift+F, Alt+Shift+Space (floating), Alt+C,
Alt+BracketLeft/Right. RED (compile) -> GREEN each task; 455 executed 0 failures (parent
spot-check); signed build OK. Gaps: no CLI/IPC equivalents; LIVE PENDING. Review: UNAVAILABLE.

Evidence NC-06/07 (route: one delegated writer): found and fixed latent bug — display never
repointed after `switchTo` (added DisplayManager.show + syncShownWorkspace). Hidden position:
bottom-right corner below the display (fallback bottom-left), floating frames remembered in
HiddenWindowBook. Switch animates vertically through the bottom edge both directions.
RED (compile) -> GREEN; 482 executed 0 failures (parent spot-check); signed build + GioPOC OK.
Gaps: multi-display floating reveal relative to first display; crash loses hidden floating
frame. LIVE PENDING. Review: UNAVAILABLE.

Decisions NC-08..NC-11 (2026-10-08, niri semantics with Alt as Mod; route: one delegated writer,
in parallel with the window-rules writer on the same tree):
- Heights reuse the per-window `heightWeights`: the action computes the wanted height (proportion
  `p * (H - 2*padding + gap) - gap` of the focused display's usable height, or points), clamps it
  so every window of the column keeps `minimumWindowHeight` = 100 pt, and writes only the focused
  window's weight (`h * others / (available - h)`), so the other windows keep their proportions.
  A lone window (it fills its column), a column too short for every minimum, no presets and a
  change under 0.5 pt are no-ops. Preset cycling mirrors widths: first preset taller than now,
  else wrap. `preset-window-heights` reuses `ColumnWidthSpec` (identical parse rule; `.standard`
  never comes from config and resolves to an equal share).
- `reset-window-height` clears every weight of the focused column (equal shares), not just the
  focused one: weights are relative, so "automatic" for one window only is meaningless next to
  others. In the common case (one window resized) this is exactly niri's result.
- `swap-window-left/right` follows niri's `swap_window_in_direction` (checked in niri
  `src/layout/scrolling.rs`): the focused window trades places with the neighbouring column's
  focused (active) window, not the same row; both columns keep their width and focused row,
  weights travel with the windows, focus follows; two lone windows = `move-column-*`; edges no-op.
  So an unequal neighbour never "absorbs" the window: it is always a trade.
- `move-column-to-workspace*` follows niri's default `focus=true` (the existing window variant
  `move-to-workspace N` keeps focus where it was, unchanged). The column lands after the target's
  focused column (niri `add_column`, like `move-column-to-monitor-*`), keeping width, maximize
  state and weights; beyond the stack opens a new workspace; an emptied source is pruned.
- `focus-workspace-previous`: `WorkspaceManager.Stack.previous` per display, set whenever the
  display's active workspace changes (`activate`, and the target of `move-workspace-to-monitor`).
  Works for named workspaces (never pruned); a pruned dynamic one or one now on another display
  is a no-op. Re-selecting the shown workspace keeps the history.
- `move-workspace-down/up` swap within the display's stack and keep the workspace shown. Refused
  for a named workspace: its place is the `[[workspace]]` order and `arrangeNamed` re-sorts on
  every reload/display change, so a move would be silently undone (same choice as
  `move-workspace-to-monitor`). The applier logs `move-workspace-<dir> refused: workspace <id> is
  named; config order places it` (id only, never the name). Dynamic workspaces never pass above the
  named block or below the spare; empty ones do not move. No focus intent (nothing changes focus),
  no shown-workspace sync; motion cause `.workspaceSwitch`.
- Defaults (all free in `defaultHotkeyBindings`, 48 -> 69, `testDefaultCombosAreUnique`):
  Alt+Home/End, Ctrl+Alt+Home/End, Alt+Shift+Minus/Equal, Alt+Shift+R (was free), Ctrl+Alt+R,
  Ctrl+Alt+U/I, Ctrl+Alt+Shift+U/I (niri's Mod+Shift+U/I are Gio's window moves), Ctrl+Alt+1..9
  (niri Mod+Ctrl+N). `focus-workspace-previous` unbound: niri's Mod+Tab = Option+Tab, the default
  of the AltTab switcher; Gio's tap would swallow it. `swap-window-*` unbound (niri ships them
  unbound too).
- Focus intent: first/last, column moves, swap, column-to-workspace and previous carry it; height
  actions are sizing (`growsFocusedWindow`, `.windowResize`), never focus.
- CLI gaps: no `gio` verb for any of these (`focus`/`move` take only directions; adding
  `first|last`, heights or workspace order is not a trivial fit). `CLICommand`/launcher unchanged.
- Known approximation: a floating window still listed in a column is counted by the height
  arithmetic (the engine drops it), so heights in such a column are approximate.

Evidence NC-08..NC-11: RED = compile failure of the new/extended tests (`swift build
--build-tests`: "cannot find 'switchPresetWindowHeight' in scope", "type 'HotkeyAction' has no
member 'focusColumnFirst'/'moveColumnToWorkspace'/'focusWorkspacePrevious'/...", missing
`presetHeightsText`). GREEN per class (xctest, signed ad hoc): WindowHeightTests 7,
ColumnNavigationTests 8, WorkspaceColumnActionsTests 10, HotkeyTests, ShortcutCatalogTests,
FocusIntentTests, FocusedGrowTests, PerAnimationConfigTests, NiriControlsConfigTests,
SettingsFormTests 0 failures; GioSessionTests.ActionApplierTests 23, 0 failures. `PresetAxis`
(UI wording for the shared chips) was written before its test (`SettingsFollowUpTests`), so no RED
was observed for it. Full `swift test` (2026-10-08, shared tree with the window-rules and updater work): GioUITests 303 (53 skipped), GioSessionTests 384, GioPOCTests 7, GioMacTests 19, GioMacOSTests 68, GioCoreTests 1628, all 0 failures; `git diff --check` clean. Signed build: parent. LIVE PENDING (TESTING row 7b).

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
- 2026-09-29: NC-06 + NC-07 done. All tasks code-complete. Next: user live test.
- 2026-09-29: user live feedback "si parece mejor". Feature closed; next work in odd/tasks/desktop-app.md.
- 2026-10-08: NC-08..NC-11 code-complete (`e564c8d`, parent commits). LIVE PENDING.
- 2026-10-09: NC-08..NC-11 committed as `e564c8d` and pushed to `main`. LIVE PENDING (TESTING.md 7b).
