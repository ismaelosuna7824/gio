# Dwindle layout: a Hyprland-style split tree per workspace

## Objective
A workspace can be laid out as Niri's scrollable strip (the default) or as a Hyprland-style
dwindle tree that fills the display, chosen per workspace (`[[workspace]] layout`,
`[layout] default-layout`) and switched live (`toggle-workspace-layout`). Every existing path
(arrival, close, minimize, rules, workspace and display moves, Move Edge, recovery) must keep
every window: no window lost or duplicated by a layout switch or a move.

## Request (2026-10-11)
User decision (Spanish chat) after the OmniWM evaluation (`local://omniwm-DwindleEval.json`):
add a Hyprland-style Dwindle layout selectable per workspace. OmniWM (`/tmp/OmniWM`, GPL-2.0)
was read for behaviour only (tree of splits and leaves, ratios 0.1...1.9, insertion by
preselection or aspect ratio, removal collapsing the parent, geometric neighbours, the
`atWorkspaceEdge` outcome); no code taken. Non-goals: tabbed or grouped tiles (OmniWM's tile
groups), gestures, SkyLight, per-monitor dwindle overrides.

## Problem (code map, 2026-10-11)
- `Workspace` was the column strip itself; `planDisplayLayout`, `ActionApplier`, the overview
  miniature, `gio layout info` and `gio status` read columns directly.
- A second membership list (a tree beside the columns) would have to be repaired on every
  arrival and removal path (`placeArrival`, `stripWindows`, `minimizeWindow` /
  `restoreWindow`, `WorkspaceManager.detach` / `insert` / `takeFocusedColumn`, display merges,
  recovery, Move Edge), each a chance to lose or duplicate a window.

## Decisions
- **One membership list (DW-01).** The columns stay the membership in both layouts; the tree
  is a view of them. `Workspace.reconcileDwindle(splitRatio:)` runs on every
  `WorkspaceManager` write (`store`: `update`, `detach`, `insert`, `takeFocusedColumn`, layout
  and named-workspace changes): leaves that left the columns are removed (parent collapses into
  the sibling), new members are inserted in column order, the selection follows the focused
  window, a maximize ends when its window loses focus, and the columns become one window each in
  leaf order. Every arrival/removal path is therefore covered without touching it, and
  `planDwindleDisplayLayout` reconciles a copy again so even a hand-built workspace never drops a
  window. A scrolling workspace keeps an empty tree. Consequence: a stacked scrolling column
  becomes one tile per window in dwindle, and comes back as one column per window (tree order)
  when switching back; the window set is preserved, the stacking is not.
- **Orientation.** A split stores `orientation` nil (follow the rectangle's shape at every layout:
  side by side when `width >= height * split-width-multiplier`) unless a preselection or
  `dwindle-toggle-split` pins it. This is Hyprland's default (`preserve_split = false`) and equals
  "by the aspect ratio of the leaf rect" at insertion, without the membership sync needing any
  geometry; a workspace moved to a portrait display re-shapes itself.
- **Insertion.** The new window splits the selected leaf (the focused window before it
  arrived; a stale selection splits the last leaf) and takes the second half (right/bottom), or
  the preselected side (left/up first). Ratio `default-split-ratio` (first child's share x 2).
- **Selection** is stored (`DwindleState.selected`), not derived: by the time the arrival is
  inserted, the focus has often already moved to it.
- **Cocoa y-up.** A stacked split puts its first child on top (the larger-y part); dwindle
  `up`/`down` are visual.
- **Fullscreen / maximize.** A focused fullscreen window covers the display and the other
  tiles park where they are (same as scrolling); an unfocused fullscreen window keeps its tile.
  `maximize-column` in dwindle is Hyprland's maximize (`fullscreen, 1`): the window fills the
  area inside the padding while it stays focused, the others stay in their tiles behind it (no
  motion for them); toggling again, focusing another window or closing it ends it.
- **Defaults.** New workspaces start with `default-layout`; an empty workspace adopts a changed
  default at once (a named one with its own `layout` keeps it); a workspace with windows keeps its
  layout. A `[[workspace]] layout` applies when the workspace is new or the key changed, so a
  runtime toggle survives an unrelated reload.
- **Limits.** Learned minimum sizes and rule `min-width` / `max-width` are scrolling-only.

## Tasks
- [ ] DW-01 — Model, engine and planning. Commit pending.
  `GioCore/Dwindle/DwindleTree.swift`, `DwindleLayoutEngine.swift`, `DwindleMembership.swift`
  (new), `Workspace/Workspace.swift` (`layout`, `dwindle`, `windows`),
  `Workspace/WorkspaceManager.swift` (`store`, `setLayout`, `toggleLayout`,
  `applyLayoutDefaults`, named layouts), `Config/WorkspaceDefinition.swift` (`layout`),
  `Layout/LayoutEngine.swift` (`LayoutConfig.dwindle`), `Layout/DisplayReflowPlanner.swift`
  (`planDwindleDisplayLayout`), `GioDesktop/SessionHost.swift` (`isVisibleInViewport`);
  docs: `docs/ARCHITECTURE.md`, this file, AGENTS.md.

## Evidence
### DW-01
- RED by compilation (`swift build --build-tests` before production code):
  `DwindleLayoutEngine` not in scope; `LayoutConfig` has no member `dwindle`;
  `WorkspaceManager` has no member `setLayout` / `toggleLayout` / `applyLayoutDefaults`;
  `WorkspaceLayoutDefaults` not in scope; `Workspace` has no member `reconcileDwindle`.
  First GREEN run: 2 failures, both in the test (`testSettingTheLayoutOfAnotherWorkspaceById`
  left an empty workspace, which is pruned); fixed the test.
- Tests: `DwindleLayoutEngineTests` (23: 1 to 5 windows, gaps and padding, zero gaps, viewport
  origin, portrait, `split-width-multiplier`, pinned orientation, ratio, ratio clamp,
  preselect left / up / down / right, insertion at the selected leaf, stale selection, removal
  collapse, selection and maximize forgotten, leaf swap, non-tiled leaves, invalid input, a
  40-window tree), `DwindleMembershipTests` (23: scrolling -> dwindle -> scrolling -> dwindle
  keeps the set and focus, tree order back into columns, layout by id, stale tree repaired, no
  tree while scrolling, idempotent reconcile, arrival with and without focus, preselection,
  rule arrival on another dwindle workspace, a stacked column arriving, close, recovery prune,
  minimize/restore, workspace moves, display moves, display removal merge, defaults, planning
  shows every tile, hand-built tree, focused and unfocused fullscreen, maximize),
  `ReflowPlannerTests.testADwindleWorkspaceShowsEveryTileAndHidesLikeAnyWorkspace`.
- GREEN: `swift test`, all bundles 0 failures: GioUITests 306 (53 skipped), GioSessionTests 400,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 83, GioCoreTests 1731. Signed `xcodebuild` BUILD
  SUCCEEDED. `git diff --check` clean.
- Not live-verified: nothing switches a workspace to dwindle before DW-02 / DW-03 (actions,
  config); see LIVE PENDING below.

## Progress
- 2026-10-11: DW-01 implemented on `feat/dwindle` (worktree `gio-wt-dwindle`).
