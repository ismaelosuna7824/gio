# Mouse drags (MD)

## Objective

OmniWM parity (comparison 2026-11-04; the user pointed at OmniWM's "Niri layout" card: "Swap, cycle,
or free-resize on both axes at once — the strip re-flows live"). Gio had the keys (swap within a
column, preset widths, focus) but nothing for the mouse. The user chose **⌥ + right-drag fluid resize**
and **⌥ + drag to move**; not edge-drag adoption, not vertical-monitor rows. OmniWM is GPL-2.0: its
README was read for behavior, no code.

## Decisions

- **Input.** The existing active event tap (`HotkeyTap`, its own thread, PF-AB) also subscribes to left
  and right drags and releases (only delivered while a button is held). `MouseDragGate` decides on the
  tap thread, under its own lock, whether to swallow: a press with exactly `mouse-drag-modifier`, over a
  tile the last pass published (shown, tiled, scrolling strip, no fullscreen window) that is the
  frontmost window there (`clickTarget`, Gio's own panels skipped: the ring sits right above its
  window). Press, drags and release go together, so the app never sees half a click. Signals reach the
  session queue through one scheduled drain per burst (latest pointer wins).
- **Live.** `MouseDragController` (GioSession) mirrors the trackpad scroll (TG-03): State does not move
  while the button is down, `performReflow` waits (`isTracking`), frames go through `GestureFramePump`
  to the reconciler's motion lanes (invariant 3, EnhancedUIGuard via the lanes), their echoes are
  recorded, and the event router treats the drag's pids as animating.
- **Resize** (`beginMouseResize`/`mouseResized`, Core): the edges nearest the grab point move; width
  as a proportion of the strip (like the width keys), clamped between `minimumColumnWidth` and the
  strip; a left-edge grab shifts the view so the right edge stays; height through
  `settingWindowHeight` (HeightStack generalized to any window). Widths `fill-empty-space` stretched are
  baked into the start so nothing jumps, and the result pauses the filling (`noteColumnsResized`).
- **Move** (`mouseDropTarget`/`movingWindow`, Core): zones on the layout the drag started from (they
  hold still while the strip makes room): a quarter of a tile's width at each side opens a column
  beside it, a quarter of its height at the top or bottom stacks into its column, the center swaps.
  Widths stay with columns; a lone window carries its column; a stacked one leaves with its column's
  width (the overview move's `leave`/`relabeled`, now shared). The moved window follows the pointer.
- **Release.** Commit only if the workspace is unchanged since the press (else abandoned: `stale`); a
  click (under 3 pt of travel) or a drop nowhere is abandoned and State lays the strip out again. The
  dragged window is focused (`requestUncenteredIntent`): the press was taken from its app, so this is
  the click's focus, not a passive one.
- **Config.** `[behavior] mouse-move-window`, `mouse-resize-window` (both default true),
  `mouse-drag-modifier` (default `"Alt"`, hotkey modifier names, exact match; unknown or empty is an
  error). Settings > Focus > Pointer.

## Tasks

- [x] MD-01 (`DONE`, `fc21c58`) — move and resize drags.
  RED: compile failure of `MouseDragTests` (GioCoreTests, 18: trigger, resize edges/clamps/height/fill
  baking, drop zones, swap/new column/stack/no-op, config) and `MouseDragControllerTests`
  (GioSessionTests, 8: live writes and commit, follow-the-pointer swap, click and drop-nowhere abandon,
  stale workspace, floating refused, focus on release, gate swallow rules, gate off). Updated:
  `TapResilienceTests` (routes and mask), `SettingsPresentationTests.testFocusDraftCollectsEveryFocusEdit`.
  Live 2026-11-04 (dev build, clean setup, two Terminal windows on an empty workspace, synthetic
  Option-drags posted at the HID tap, widths from the window server):
  - first run took nothing: the focus ring (layer 0, ordered above its window) made
    `topWindowOwnerPID` answer Gio; fixed with `clickTarget(ownPID:)`.
  - right-drag +100 pt on the left window's right half: 741 → 846 (`result=resized`,
    `focusChanged=true`), the neighbour moved to 860.
  - Option-drag onto the other window's center: `result=swap`.
  - Option-click without travel: `result=none`, nothing moved.
  - drag onto the other window's top edge: `result=stack above`, both 469 pt high in one column.
  - drag the top one onto the bottom one's right edge: `result=column after`, width kept (846).
  - a keyboard `focus-right` afterwards reflowed at once; `NSEvent.pressedMouseButtons` was 0 (the
    swallowed release did not leave the button down).
  Seen, not changed: a notch app (Droppy) keeps a layer-100 window over the top of the screen, so a
  press there is not taken (the frontmost window is not the tile). NOT verified live: a real mouse or
  trackpad drag by hand, the Settings rows, a second display, a dwindle workspace (refused by design).
- [x] MD-02 (`DONE`, `191a37b`) — Layout preview like OmniWM's "Niri layout" card (user, 2026-11-04:
  "me refiero a la vista layout"). Settings > Layout > Preview now draws a desktop with a menu bar (none
  in the Fullscreen mode), windows with traffic lights, titles and content, the focused one ringed in the
  accent with a glow and stacked over a second window in its column (the configured gap between them),
  and under it the strip's keys as bound now (`layoutKeyHints`: move down, cycle width, the drag
  modifier's resize and move, focus right). `launcherHotkey(in:)` became `shownHotkey(for:in:)` (every
  caller migrated). RED: compile failure of `KeybindingEditingTests.testAnyActionShowsItsCurrentCombo`;
  `SettingsPresentationTests.testLayoutKeyHintsFollowTheConfig` was written with its function (no RED
  observed). Visual check: `SnapshotHarness` renders of the preview in Columns, Maximized and Fullscreen,
  dark and light (throwaway, deleted). Full `swift test`: Core 2281, Session 607, UI 389 (snapshots on),
  POC 7, Mac 19, macOS 120; signed build OK. NOT viewed in the running app.
- [x] MD-03 (`DONE`, `d4bcf67`) — mouse drags removed (user, 2026-11-04: "creo que vamos a quitar la
  funcionalidad del drag, mejor hay que eliminarla"). `fc21c58` reverted: no `[behavior] mouse-*` keys
  (an old line now warns as an unknown key), no drag/up events in the tap mask, no `MouseDragGate`,
  `MouseDragController` or Core drag code, no Settings > Focus > Pointer rows; `settingWindowHeight`,
  `parseModifiers` and the shared overview-move helpers went with it. The Layout preview (MD-02) keeps
  its keyboard hints: move down, stack left, cycle width, wider, narrower, focus right. The bug in the
  same report (Activity Monitor active but invisible) was not the drag (no `mouse move` line at the
  time): FI-13 in `fidelity.md`.
