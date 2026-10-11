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
- **Orientation (DW-01, refined in DW-02).** The membership sync has no geometry, so a new split
  stores `orientation` nil (follow the rectangle: side by side when
  `width >= height * split-width-multiplier`), and the first pass that lays it out pins it to
  that shape (`DwindleNode.pinningOrientations` in `planDwindleDisplayLayout`; the host stores
  the planned workspace back, like the viewport offset). Net: decided by the aspect ratio of the
  leaf it split, on the display that first shows it, and kept (OmniWM, Hyprland
  `preserve_split`). DW-01 first kept every split free (Hyprland's `preserve_split = false`);
  a DW-02 test showed the cost: growing the left half to 60% turned the right half (582x580)
  side by side and flipped its stacked windows. The sizing actions also pin the splits they
  measure before changing a ratio. A preselection or `dwindle-toggle-split` pins explicitly. A
  workspace moved to a display of another shape keeps its shapes (toggle to change).
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
- **Actions (DW-02).** Pure Core functions over `DwindleGeometry` (usable frame of the display
  showing the workspace, modes, `LayoutConfig`); `ActionApplier.applyDwindle` is exhaustive so a
  future action must choose: dwindle meaning, no-op, or layout-independent (`return false` to the
  common switch). Shared mapping: focus = geometric neighbour (nearest tile past the edge that
  overlaps on the other axis; then overlap, centre, leaf order); `move-*`, `move-column-*`,
  `swap-window-*` = swap leaves, focus stays on the moved window; `.atEdge` lets
  `moveColumnOrToDisplay` / `focusColumnOrDisplay` cross displays (Move Edge and
  `move-crosses-monitor-at-edge`); `focus-window-or-workspace-*` = tile, else workspace;
  `focus-column-first/last` = first/last leaf. A focused floating window navigates from its
  (invisible) leaf.
- **Resize: reuse, no `dwindle-resize-*` actions.** The width actions (`set-column-width-*`,
  `switch-preset-column-width[-back]`) act on the nearest side-by-side split above the focused
  window, the height actions (`set-window-height-*`, `switch-preset-window-height`,
  `reset-window-height`) on the nearest stacked split: +-10% of that split, presets as the
  focused window's share of the split (points measured against it), reset = half and half.
  Existing muscle memory works; nothing new to bind.
- **No-ops in dwindle:** `center-column`, `center-visible-columns`,
  `expand-column-to-available-width`, `consume-or-expel-window-*`, `move-column-to-first/last`.
  `maximize-column` = the zoom above (no native-zoom request: NZ-01 is a column-width feature).
- **Bindings.** `toggle-workspace-layout` = `Alt+Shift+T`: the requested `Alt+Shift+Space` is
  `toggle-floating` (a default since FI); `T` for "tiling layout" was free in every modifier set
  Gio uses. `dwindle-balance` = `Alt+Shift+B` (OmniWM's default, free). Everything else ships
  unbound like OmniWM's toggle/swap/preselect. Default bindings 75 -> 77. New Shortcuts category
  **Layout**. None of the new actions carries a focus intent (the focused window stays);
  motion causes: layout switch and swap-split `window-movement`, toggle-split and balance
  `window-resize`, preselect `passive`.
- **Edge semantics.** `ColumnLanding` stays as MM-06 for a scrolling target; in a dwindle target
  the landing order is irrelevant (the arrival splits that workspace's focused window).
- **CLI.** `gio focus` / `gio move` follow the tree (`CommandSession.dwindleGeometry`, from
  `visibleFrames` that `SessionHost` fills before every IPC dispatch, and the registry modes).

## Tasks
- [x] DW-01 — Model, engine and planning. Commit `3980d44` (rebased from `cdef806`).
  `GioCore/Dwindle/DwindleTree.swift`, `DwindleLayoutEngine.swift`, `DwindleMembership.swift`
  (new), `Workspace/Workspace.swift` (`layout`, `dwindle`, `windows`),
  `Workspace/WorkspaceManager.swift` (`store`, `setLayout`, `toggleLayout`,
  `applyLayoutDefaults`, named layouts), `Config/WorkspaceDefinition.swift` (`layout`),
  `Layout/LayoutEngine.swift` (`LayoutConfig.dwindle`), `Layout/DisplayReflowPlanner.swift`
  (`planDwindleDisplayLayout`), `GioDesktop/SessionHost.swift` (`isVisibleInViewport`);
  docs: `docs/ARCHITECTURE.md`, this file, AGENTS.md. LIVE PENDING.
- [x] DW-02 — Actions and shared-action mapping. Commit `c978296` (rebased from `c95f162`).
  `GioCore/Dwindle/DwindleActions.swift` (new), `DwindleTree.swift` (`pinningOrientations`),
  `DwindleLayoutEngine.swift` (`orientations`), `Layout/DisplayReflowPlanner.swift` (pinning),
  `Hotkeys/HotkeyDispatcher.swift` (7 cases, 2 bindings), `Hotkeys/ShortcutCatalog.swift`
  (Layout category, entries), `Config/ConfigParser.swift` (names), `Config/ConfigTemplate.swift`,
  `Config/AnimationKinds.swift`, `Focus/FocusIntent.swift`, `Workspace/MoveEdge.swift`,
  `Workspace/WorkspaceManager.swift` (`focusWindowOrWorkspace*` geometry),
  `Commands/CommandDispatcher.swift` (`visibleFrames`, `dwindleGeometry`, focus/move),
  `GioSession/Actions/ActionApplier.swift` (`applyDwindle`, layout cases),
  `GioDesktop/SessionHost.swift` (IPC `visibleFrames`); docs: README, USER_GUIDE (Dwindle
  layout section, shortcuts), ARCHITECTURE, TESTING (check 14d, limitation), CONTRIBUTING,
  AGENTS.md, this file. LIVE PENDING.
- [x] DW-03 — Config and Settings UI. Commit `62fea5d`.
  `Config/GioConfig.swift` (`LayoutSectionConfig.defaultLayout`, `DwindleSectionConfig`,
  `GioConfig.dwindle`, `layoutDefaults`, `makeLayoutConfig()` fills `LayoutConfig.dwindle`),
  `Config/ConfigParser.swift` (`[dwindle]` section, `applyDwindleKey`, `default-layout`,
  `[[workspace]] layout`), `Config/ConfigPatcher.swift` (`renderWorkspace` writes `layout`),
  `Config/ConfigTemplate.swift`, `Config/SettingsForms.swift` (`LayoutSettingsForm`: default
  layout, ratio, multiplier), `Commands/CommandDispatcher.swift` (`CommandSession.config`
  applies `applyLayoutDefaults` before `applyNamedWorkspaces`), `GioUI/Settings/
  LayoutSettingsView.swift` (Workspace Layout card), `GioUI/Workspaces/WorkspacesPresentation.swift`
  (`WorkspaceCardDraft.layout`, `workspaceLayoutOptions`, `workspaceLayoutLabel`),
  `WorkspacesSettingsView.swift` (Layout popup per card); docs: USER_GUIDE (config reference),
  TESTING (14e), ARCHITECTURE, this file. LIVE PENDING.
- [x] DW-04 — Overview, IPC and CLI. Commit `9b7d196`.
  `Layout/DisplayReflowPlanner.swift` (`workspaceLayoutResult`), `Commands/WorkspaceMiniature.swift`
  (dwindle tiles measured from the top), `GioSession/Publication/SessionFactsBuilder.swift`
  (strips from either layout), `Dwindle/DwindleTree.swift` (`dwindleTreeSummary`),
  `Workspace/WorkspaceStackSummary.swift` (`WorkspaceEntry.layout`), `IPC/IPCHandler.swift`
  (status `layout`, `dwindle`), `Commands/CLICommand.swift` (`setLayout`, parse, usage),
  `Commands/CommandDispatcher.swift` (layout info, list-workspaces, `gio layout`),
  `GioSession/IPCRouter.swift` (reflow), `GioUI/LauncherModel.swift` (`describeAction`); docs:
  USER_GUIDE (CLI), ARCHITECTURE, TESTING (14e), this file. LIVE PENDING.

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

### DW-02
- RED by compilation (`DwindleActions.swift` moved out of the target, `swift build
  --build-tests`): `dwindleFocus`, `dwindleMove`, `dwindleToggleSplit`, `dwindleSwapSplit`,
  `dwindleBalance`, `dwindlePreselect`, `dwindleResize`, `dwindleSwitchPreset`,
  `dwindleResetSplit`, `dwindleToggleMaximize`, `dwindleFocusEnd`, `focusNeighbour`,
  `DwindleGeometry` not in scope; extra argument `geometry` (`moveColumnOrToDisplay`,
  `focusColumnOrDisplay`, `focusWindowOrWorkspaceDown`); `HotkeyAction` without the new cases.
  First GREEN run: 5 failures: `testWidthStepsMoveTheNearestSideBySideSplit` (286 instead of 582:
  the inner split flipped, which led to orientation pinning above) and the intended changes
  (bindings 75 -> 77 in `HotkeyTests` x2 and `MoveEdgeTests`, the category list in
  `ShortcutCatalogTests`), updated.
- Tests: `DwindleActionsTests` (25: neighbours in all directions and the edges, a focused
  floating window, portrait, first/last, swap and focus kept, `.atEdge`, `.unchanged`,
  toggle-split both ways, swap-split keeps sizes, balance, preselect, maximize, width and height
  steps, limits, presets incl. points, reset, pinning, scrolling no-ops, Move Edge inside then
  across, into a dwindle target, without a neighbour, focus edge, focus-or-workspace, names /
  bindings / catalog / motion causes, `gio focus` / `gio move`),
  `DwindleMembershipTests.testTheFirstLayoutPinsEachShownSplitToItsShape`, `ActionApplierTests`
  (6 new: layout switch, shared focus/move, column-only no-ops, sizing + maximize without native
  zoom, dwindle-only no-ops on scrolling, Move Edge from the tree with the toggle; `allActions`
  extended so focus intent, sync and engine/mode laziness are checked for the new cases).
- GREEN: `swift test`, all bundles 0 failures: GioUITests 306 (53 skipped), GioSessionTests 406,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 83, GioCoreTests 1757. Signed `xcodebuild` BUILD
  SUCCEEDED. `git diff --check` clean.

### DW-03
- Decisions: invalid layout/dwindle values are **warnings that keep the default** (the brief's
  rule; the repo's general rule makes a wrong value an error that rejects the file, but a layout
  typo must not drop the user's whole config). Wrong type or out of range alike: ratio outside
  0.1-1.9, multiplier outside 0.1-10, layout other than "scrolling"/"dwindle". `smart-split` is
  omitted with its own warning: it needs the pointer position when a window opens, which the
  pure membership sync does not have (use `dwindle-preselect-*`). The Layout form writes the
  three keys with the others on Apply (`[dwindle]` is created at the end of the file when
  missing, comments kept). A runtime toggle never writes the config; a `[[workspace]] layout`
  applies when the workspace is created or the key changes.
- RED by compilation: `DwindleSectionConfig` not in scope; `GioConfig` has no `dwindle` /
  `layoutDefaults`; `LayoutSectionConfig` has no `defaultLayout`; extra argument `dwindle`
  (`LayoutSettingsForm`); `WorkspaceCardDraft` has no `layout`; no `workspaceLayoutOptions` /
  `workspaceLayoutLabel`. First GREEN run: 1 failure, `NamedWorkspaceConfigTests.
  testUnknownWorkspaceKeyWarns` used `layout` as its unknown key; it now uses `gaps`.
- Tests: `DwindleConfigTests` (8: defaults, valid parse incl. three workspaces, every invalid
  value warns with its line and keeps the default, `smart-split` warning, template, patch keeps
  comments and round-trips `[[workspace]] layout`, Layout form fields / problems / edits, the
  session applies defaults and named layouts and keeps a runtime toggle across an unchanged
  reload, PF-M transport: dwindle tile changes stay on Accessibility and a dwindle hide goes
  through the WindowServer), `DwindleWorkspaceCardTests` (card layout round trip and labels).
- GREEN (on the rebased branch with PF-K/L/M): GioUITests 308 (53 skipped), GioSessionTests 407,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 89, GioCoreTests 1809, all 0 failures. Signed
  `xcodebuild` BUILD SUCCEEDED. `git diff --check` clean. Before DW-03 the rebased branch was
  green too: GioUITests 307 (53 skipped), GioSessionTests 407, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 89, GioCoreTests 1801.

### DW-04
- Decisions: the overview keeps its strip model; a dwindle workspace gives one strip fact per
  tile (its columns are one window each, in leaf order) with frames from
  `workspaceLayoutResult`, and `top` measured from the viewport's top so the y-down drawing
  matches the Cocoa y-up screen (the scrolling strip keeps its old `top` measure; see the note
  below). Tree summary notation: `(a | b)`, `(a / b)`, `(a ~ b)` for a split no layout shaped yet,
  ratio after the sign when not 1. `gio layout info` starts with `layout=...`; scrolling output is
  otherwise unchanged. `gio layout toggle|scrolling|dwindle` changes the live layout only (never
  the config) and reflows without a focus intent; an unknown argument is refused with
  `missingArgument(info|toggle|scrolling|dwindle)`.
- Observation, not changed: the scrolling engine places a column's first window at the lowest y
  (the bottom in Cocoa), and the miniature measures `top` from `minY`; whether stacked windows
  read upside down on screen or in the miniature needs a live look.
- RED by compilation: `workspaceLayoutResult`, `dwindleTreeSummary` not in scope; `CLICommand`
  has no member `setLayout`. First GREEN run: 1 failure, `CommandDispatcherTests.
  testParseRejectsJunk` expected the old `missingArgument(name: "info")`; updated.
- Tests: `DwindleOverviewIPCTests` (6: strip of a dwindle workspace from tiles, top-down, none
  parked, focus; scrolling strip unchanged; status `layout` / `dwindle` / per-workspace layouts;
  tree summary with shapes and ratios; layout info and list-workspaces; the `gio layout` verbs
  parse, refuse junk, switch and report).
- GREEN: GioUITests 308 (53 skipped), GioSessionTests 407, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 89, GioCoreTests 1815, all 0 failures. Signed `xcodebuild` BUILD SUCCEEDED.
  `git diff --check` clean.

## LIVE PENDING
Nothing in DW-01..DW-04 ran on a real desktop (the user's Gio was running; no live runs from an
agent). Checks 14d (actions, tree behaviour, Move Edge) and 14e (config, Settings, overview,
CLI) in `docs/TESTING.md`, signed Gio scheme.

## Progress
- 2026-10-11: DW-01 (`cdef806`) and DW-02 (`c95f162`) committed on `feat/dwindle` (worktree
  `gio-wt-dwindle`, not pushed, not merged), verified automatically; LIVE PENDING (check 14d).
- 2026-10-11: branch rebased by the main agent onto main with PF-K/L/M (DW-01 `3980d44`, DW-02
  `c978296`, docs `9610f69`); green on the rebase. DW-03 committed as `62fea5d`, DW-04 as
  `9b7d196` (not pushed, not merged). LIVE PENDING (checks 14d, 14e).
