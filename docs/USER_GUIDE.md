# User guide

How to use Gio day to day: shortcuts, configuration, window rules, the desktop app and the command line. Everything here is derived from `defaultHotkeyBindings`, `ShortcutCatalog`, the config parser and the command grammar in the source.

Contents: [Concepts](#concepts) · [Shortcuts](#default-shortcuts) · [Dwindle layout](#dwindle-layout) · [Config](#configuration-reference) · [Rules](#window-rules) · [Desktop app](#desktop-app) · [Launcher](#launcher) · [Overview](#workspace-overview) · [CLI](#command-line-gio) · [Updates](#updates) · [gio-poc](#gio-poc)

## Concepts

- **Strip and viewport.** Each workspace is a horizontal strip of **columns**. A column stacks one or more windows vertically. The display is a viewport onto the strip and scrolls to keep the focused column visible.
- **Layouts.** A workspace is either the scrolling strip above (the default) or a **dwindle** tree: every window on screen, each new one splitting the focused one (Hyprland's dwindle). Each workspace has its own layout; `Alt+Shift+T` (`toggle-workspace-layout`) switches the current one and keeps every window. See [Dwindle layout](#dwindle-layout).
- **Workspaces.** Niri-style dynamic vertical stack, one per display. You start with one empty workspace. Putting a window in the last (empty) workspace opens a new empty one below it, so there is always exactly one empty workspace at the bottom. An empty workspace you are not on is removed: leave it and it disappears, and the indices below it shift up. Windows are never lost when a workspace disappears (it only ever disappears when it is empty), and a display that is unplugged hands its windows to a remaining display's stack. `Alt+1` to `Alt+9` address the workspace at that position in the focused display's stack; a number past the end of the stack goes to the empty workspace at the bottom. Windows of workspaces that no display shows are hidden off the bottom corner of the display. Every switch, up or down, animates vertically through the bottom edge because macOS cannot place windows above the menu bar. When macOS itself focuses a window on a hidden workspace (App Exposé with Control+Down, Mission Control, the Dock), Gio switches to that workspace and shows the window.
- **Named workspaces.** Each `[[workspace]]` in the config is a named workspace. It always exists, even empty (it is never removed when you leave it), and named workspaces come first in their display's stack in config order, so `Alt+1` is the first one; dynamic workspaces follow them with the rules above (the empty one at the bottom is always dynamic). On a display that shows an empty dynamic workspace when named ones first appear (at startup), Gio opens on the first named one. Window rules with `open-on-workspace` send an app's new windows there (see [Window rules](#window-rules)). Without `[[workspace]]` nothing changes.
- **Multiple monitors.** Each display shows one workspace of its own stack, and one display is focused: the one keyboard actions, `Alt+1`...`Alt+9` and new windows use. `Ctrl+Alt+H/J/K/L` (`focus-monitor-*`) focuses the display on that side (by position in System Settings > Displays; nothing happens when there is none) and the workspace it shows; its focused window takes the keyboard, and with `mouse-follows-focus` the cursor follows (to the window, or to the middle of the display when it shows no window). `Ctrl+Alt+Shift+H/J/K/L` (`move-column-to-monitor-*`) sends the focused column, with its windows and width, to the workspace that display shows, next to its focused column, and focus follows. `Ctrl+Alt+Cmd+H/J/K/L` (`move-window-to-monitor-*`) sends only the focused window (as its own column), and the menu bar's **Move Window to Display** submenu (or `> move-window-to-display N` in the launcher, `gio move-window-to-display N`) sends it to display N. `move-workspace-to-monitor-*` ships unbound and sends the whole workspace to that display's stack (after its active workspace, shown there); the display left behind shows the workspace below (or above when only the empty one is below). Named workspaces stay on the display config gives them: their columns can move, the workspace itself cannot. The display you leave keeps showing what it showed, even an emptied workspace, until you switch it. A floating window carried by these moves goes to the other display with its workspace: same size, same offset from the corner of the usable area, kept inside it. Hidden windows never show on another display: a display with another display right below it (an external monitor above the laptop) switches workspaces without the vertical slide, and its hidden windows hang off its bottom corner or, when the display below is in the way, off its side. No window straddles two displays: a column that would peek over an edge another display shares (the neighbour of a centered column, for example) is parked off the display's free side instead (its window jumps there, never across the display; with the snapshot renderer you see it slide out by the shared edge, cut at that edge, and slide back in from it); a peek over a free edge stays, and the focused column is always shown. So that such a parked neighbour does not leave an empty side, with `center-focused-column = "never"` the focused column moves flush against the shared edge (on a laptop with the external display on its left, the focused column sits at the left and the next one peeks on the right). When that cannot help (the last column of the strip next to a maximized one) and `maximize-single-window` is on, the focused column fills the display, like a window alone on it, and gets its own width back when you focus another column. Display numbers (`display = N`, the menu, the launcher) count the main display as 1 and the others by position, left to right; the log lists them (`display index=... number=N`) at startup and after every display change. Plugging or unplugging a display while Gio runs re-syncs once the burst of macOS notifications is over (a quarter second) and lays everything out without animation: a named workspace with `display = 2` moves to the new display and back to the main one when it goes.
- **Crossing displays at the strip's edge (MM-06).** `move-column-left-or-to-monitor-left` / `move-column-right-or-to-monitor-right` move the column inside the strip like `move-column-left/right`; when it already is the first (last) column they send it to the display on the left (right), and `focus-column-or-monitor-left` / `-right` focus the neighbouring column or, from the first (last) column, that display (niri's actions of the same names; unbound by default). The column enters by the edge it crossed: moving right it becomes the **first** column of the workspace the target display shows, moving left the **last**, and that display scrolls to show it; focus follows. (niri itself puts it after the target's focused column, like `move-column-to-monitor-*`, which keeps doing so in Gio.) No display that way: nothing happens. `[behavior] move-crosses-monitor-at-edge = true` (OmniWM's Move Edge; Settings > Focus > Displays > **Move windows and columns across displays at the edge**) gives the plain `move-column-left/right` (`Alt+Shift+<` / `>`) the same edge behaviour, and lets the window move (`Alt+Shift+H/J/K/L`, `gio move`) carry the window across from the workspace's edge (NC-14).
- **Modes.** A window is `tiled` (in the strip), `floating` (managed but outside the strip, keeps its own frame) or `fullscreen` (Gio's layout mode filling the display under the menu bar with a small gap around it, see `fullscreen-gap`; not a native macOS fullscreen Space).
- **Native tabs.** Apps with macOS window tabs (Terminal, Ghostty, Finder, TextEdit, Xcode) keep one tile per tab group: `Cmd+T` opens the new tab in the window's tile instead of a new column, switching tabs keeps the tile (only the tab you see is moved), closing the shown tab leaves the next one in the tile, and dragging a tab out to its own window gives it a column of its own. A tab that already existed when Gio started joins its window's tile the first time you click it. Not handled: **Window > Merge All Windows** on windows Gio already tiles (each keeps its own column), and the tab bar's order (after closing the shown tab, the tile briefly holds the next tab Gio knows until macOS reports the one it shows).
- **Mission Control.** Control+Up shows every window Gio parks off-screen too, so the thumbnails come out tiny. Turn on **System Settings > Desktop & Dock > Group windows by application** (`defaults write com.apple.dock expose-group-apps -bool true && killall Dock`) to get them back to a usable size, or use Gio's own overview (`toggle-overview`, `Alt+O`), which shows each workspace as a row.
- **Alt** means the **Option** key.

## Default shortcuts

Shortcuts are global while Gio runs and Accessibility permission is granted. A bound combo is swallowed (the app never sees it); everything else passes through untouched. All shortcuts below except the launcher can be rebound from the app's **Shortcuts** section or in `[keybindings]`.

| Shortcut | Action (config name) | What it does |
| --- | --- | --- |
| `Alt+H` | `focus-left` | Focus the column to the left. |
| `Alt+L` | `focus-right` | Focus the column to the right. |
| `Alt+K` | `focus-up` | Focus the window above in the current column. |
| `Alt+J` | `focus-down` | Focus the window below in the current column. |
| `Alt+Home` / `Alt+End` | `focus-column-first` / `focus-column-last` | Focus the leftmost / rightmost column of the workspace. |
| (unbound) | `focus-window-or-workspace-down` / `focus-window-or-workspace-up` | Like `focus-down` / `focus-up`, but from the last (first) window of the column, or an empty workspace, it goes to the workspace below (above). Niri offers it as an alternative for Mod+J/K; bind it, e.g. `"Alt+J" = "focus-window-or-workspace-down"`. |
| `Alt+Shift+H` (also `Alt+[`) | `consume-or-expel-window-left` | Move the window left (OmniWM's window move, NC-14): a window sharing its column moves out into its own column on the left; a window alone in its column joins the left column at its bottom and stays focused. A lone window in the first column stays put, unless `move-crosses-monitor-at-edge` sends it to the display on the left, at the bottom of that workspace's last column (its own column when the workspace is empty). |
| `Alt+Shift+L` (also `Alt+]`) | `consume-or-expel-window-right` | Same, to the right; across the edge it lands at the bottom of the target's first column. |
| `Alt+Shift+K` | `move-up` | Move the focused window up within its column. From the column's top, `move-crosses-monitor-at-edge` sends it to the display above, at the bottom of that workspace's focused column. |
| `Alt+Shift+J` | `move-down` | Move the focused window down within its column; from the bottom, the same edge crossing to the display below. |
| `Alt+Shift+Comma` / `Alt+Shift+Period` (the `<` / `>` keys) | `move-column-left` / `move-column-right` | Swap the focused window's column with the one on its left / right. The column keeps its windows and sizes; focus stays on the same window. With `move-crosses-monitor-at-edge`, the first (last) column goes to the display on the left (right) instead. (`Alt+Shift+H/L` until NC-14; `Option+Shift+Left/Right` stay free for word selection in text fields.) |
| `Ctrl+Alt+Home` / `Ctrl+Alt+End` | `move-column-to-first` / `move-column-to-last` | Move the focused column to the start / end of the strip; it keeps its windows and sizes. |
| (unbound) | `swap-window-left` / `swap-window-right` | Trade places with the focused window of the left / right column (niri: that column's focused window, not the same row). Columns keep their widths; focus follows the window. Two lone windows: the column moves, like `move-column-*`. |
| `Alt+R` | `switch-preset-column-width` | Cycle the focused column through the preset widths (first preset wider than the current width, wrapping). |
| (unbound) | `switch-preset-column-width-back` | Cycle the preset widths in reverse (last preset narrower than the current width, wrapping). Niri binds it to Mod+Shift+R, which is the window-height cycle in Gio. |
| `Alt+Minus` | `set-column-width-minus` | Make the focused column 10% narrower (clamped between the minimum width of 200 pt and the full strip). |
| `Alt+Equal` | `set-column-width-plus` | Make the focused column 10% wider. |
| `Alt+F` | `maximize-column` | Make the focused column fill the display width; press again to restore the previous width. |
| `Alt+C` | `center-column` | Scroll the view so the focused column is centered (clamped at the strip edges). |
| `Ctrl+Alt+F` | `expand-column-to-available-width` | Make the focused column fill the space the other fully visible columns leave; the view scrolls so the group fills the display between the paddings. Nothing happens without room to grow. |
| `Ctrl+Alt+C` | `center-visible-columns` | Scroll the view so the fully visible columns (and the focused one) are centered, clamped at the strip edges. |
| `Alt+Shift+Space` | `toggle-floating` | Switch the focused window between tiled and floating. A window whose app keeps putting it back where it wants (an installer re-centring itself) floats by itself after three such snap-backs and Gio stops moving it (Overview: **Floating · App-controlled**, log `window yields to app`); toggle it to tile it again. |
| `Alt+Shift+R` | `switch-preset-window-height` | In a stacked column, cycle the focused window through `preset-window-heights` (first preset taller than now, wrapping); the other windows share the rest in their current proportions. |
| `Alt+Shift+Minus` / `Alt+Shift+Equal` | `set-window-height-minus` / `set-window-height-plus` | Make the focused window 10% of the usable height shorter / taller. Every window of the column keeps at least 100 pt; a window alone in its column always fills it. |
| `Ctrl+Alt+R` | `reset-window-height` | Give every window of the focused column an equal share of its height again. |
| `Alt+Shift+F` | `fullscreen` | Toggle fullscreen for the focused window. It stays fullscreen when you focus another window: it keeps its full size and slides out of view like any column (the other window shows in the normal layout), and fills the display again when you focus it back, until you press the shortcut on it again; closing or minimizing it also ends it. |
| `Alt+U` | `focus-workspace-down` | Focus the workspace below in this display's stack (stops at the empty one at the bottom). |
| `Alt+I` | `focus-workspace-up` | Focus the workspace above. |
| `Alt+Shift+U` | `move-window-to-workspace-down` | Send the focused window one workspace down and follow it. From the last workspace with windows it lands in the empty one at the bottom, which opens a new empty workspace below. |
| `Alt+Shift+I` | `move-window-to-workspace-up` | Send the focused window one workspace up and follow it. |
| `Ctrl+Alt+U` / `Ctrl+Alt+I` | `move-column-to-workspace-down` / `move-column-to-workspace-up` | Send the whole focused column (windows, width, heights) one workspace down / up, next to that workspace's focused column, and follow it. Down from the last workspace with windows opens a new one. |
| `Ctrl+Alt+Shift+U` / `Ctrl+Alt+Shift+I` | `move-workspace-down` / `move-workspace-up` | Move the current workspace one place down / up in this display's stack; it stays shown. Refused (and logged) for a named workspace, whose place comes from the order of `[[workspace]]` blocks; dynamic workspaces never pass above the named ones or below the empty one at the bottom, and an empty workspace does not move. |
| (unbound) | `focus-workspace-previous` | Go back to the workspace this display showed before; again to return. Each display keeps its own history; a workspace that was removed (emptied and left) cannot be returned to. Niri binds it to Mod+Tab, but Option+Tab is the default of app switchers such as AltTab, so Gio leaves it to you, e.g. `"Ctrl+Alt+Tab" = "focus-workspace-previous"`. |
| `Alt+1` ... `Alt+9` | `workspace N` | Focus the workspace at position N of this display's stack; past the end goes to the empty one at the bottom. |
| `Alt+Shift+1` ... `Alt+Shift+9` | `move-to-workspace N` | Send the focused window to position N (past the end: the empty one at the bottom). Focus stays where it was. |
| `Ctrl+Alt+1` ... `Ctrl+Alt+9` | `move-column-to-workspace N` | Send the whole focused column to position N (past the end: the empty one at the bottom) and follow it, like niri. |
| `Alt+O` | `toggle-overview` | Open or close the [workspace overview](#workspace-overview): every workspace of this display as a row of window thumbnails. |
| `Ctrl+Alt+H` / `Ctrl+Alt+L` | `focus-monitor-left` / `focus-monitor-right` | Focus the display on the left / right and the workspace it shows (see [Multiple monitors](#concepts)). No display there: nothing happens. |
| `Ctrl+Alt+K` / `Ctrl+Alt+J` | `focus-monitor-up` / `focus-monitor-down` | Focus the display above / below. |
| `Ctrl+Alt+Shift+H` / `Ctrl+Alt+Shift+L` | `move-column-to-monitor-left` / `move-column-to-monitor-right` | Send the focused column (all its windows, same width) to the workspace the display on the left / right shows, next to its focused column, and follow it. |
| `Ctrl+Alt+Shift+K` / `Ctrl+Alt+Shift+J` | `move-column-to-monitor-up` / `move-column-to-monitor-down` | Same, to the display above / below. |
| `Ctrl+Alt+Cmd+H` / `J` / `K` / `L` | `move-window-to-monitor-left`, `-down`, `-up`, `-right` | Send only the focused window, as its own column, to the workspace the display on that side shows, and follow it (niri leaves this one unbound; Command stands for "window" next to the column move's Shift). |
| (unbound) | `move-workspace-to-monitor-left`, `-right`, `-up`, `-down` | Send the current workspace to the stack of the display on that side (after its active workspace, shown there) and follow it; the display left behind shows its next workspace. Refused for a named or empty workspace. Bind it in `[keybindings]`. |
| (unbound) | `move-column-left-or-to-monitor-left` / `move-column-right-or-to-monitor-right` | Like `move-column-left` / `-right`; from the first (last) column, send it to the display on the left (right), where it lands as the last (first) column, and follow it (see [Crossing displays](#concepts)). Bind it, e.g. `"Alt+Shift+Left" = "move-column-left-or-to-monitor-left"`. |
| (unbound) | `focus-column-or-monitor-left` / `focus-column-or-monitor-right` | Like `focus-left` / `-right`; from the first (last) column, focus the display on the left (right) and the workspace it shows. |
| `Alt+Shift+T` | `toggle-workspace-layout` | Switch the current workspace between the scrolling strip and the [dwindle](#dwindle-layout) tree; every window stays, the focused one keeps the focus. |
| (unbound) | `set-workspace-layout-scrolling` / `set-workspace-layout-dwindle` | Lay the current workspace out as the strip / the dwindle tree (nothing happens when it already is). |
| `Alt+Shift+B` | `dwindle-balance` | Dwindle: every split of the workspace back to half and half (OmniWM's default combo). Does nothing on a scrolling workspace. |
| (unbound) | `dwindle-toggle-split`, `dwindle-swap-split`, `dwindle-preselect-left` / `-right` / `-up` / `-down`, `dwindle-preselect-clear` | Dwindle only; see [Dwindle layout](#dwindle-layout). |
| `Alt+Space` | (launcher, fixed) | Summon the launcher panel. Handled by the app before the action table; not configurable. |

That is 79 default action bindings plus the launcher (`consume-or-expel-window-left/right` have two each: `Alt+Shift+H/L` and `Alt+[` / `Alt+]`). The **Shortcuts** section of the app lists the same table live, with the source of each binding (`default` or `config`), and edits it. Most actions have a dwindle meaning on a dwindle workspace; see [Dwindle layout](#dwindle-layout).

Notes:

- `Alt+Shift+H/J/K/L` move the **window** (NC-14, like OmniWM's Option+Shift+arrows): left/right are niri's `consume-or-expel-window-left/right` (a stacked window gets its own column, a lone one joins the neighbouring column), up/down `move-up`/`move-down`. `move-column-left`/`move-column-right` (`Alt+Shift+<` / `>`) swap whole columns (a no-op at the strip edge, unless `move-crosses-monitor-at-edge` sends the column to the next display). With one display, or none on that side, the window or column stays at the edge (no wrap-around). The older `move-window-left`/`move-window-right` (alias `move-left`/`move-right`, append the window to the neighbouring column) are still valid config names but are unbound by default. `gio move left|right|up|down` is the window move, like the hotkeys, including the edge crossing.
- Shrink/grow always end as a proportion of the display, so the column adapts across displays.
- Window heights in a column are relative shares: a height action computes the share that gives the focused window the wanted height on the display it is on, and the other windows keep their proportions. A floating window that still belongs to a column is counted as if it were tiled, so heights in such a column are approximate.
- None of the column, height or workspace-order actions has a `gio` CLI verb yet (the CLI covers `focus`, `move` and `workspace N`).
- Fullscreen parks every tiled window where its column already is, so leaving fullscreen finds the strip unchanged.
- Focus, move, workspace, monitor, consume/expel and fullscreen actions also move macOS keyboard focus to the target window (right away, at the start of the animation; the end of the animation only re-asserts it if focus drifted). Rapid key presses during an animation merge into one retarget per display frame. Sizing, centering and floating actions leave focus alone, and so do clicks and window events. `focus-monitor-*` onto a display that shows no window has no window to focus: keyboard focus stays where it was (only the focused display and, with `mouse-follows-focus`, the cursor move).

## Dwindle layout

A workspace can lay its windows out as a **dwindle** tree instead of the scrolling strip (Hyprland's dwindle; OmniWM has the same per-workspace choice). The usable display area (inside `padding`) is split in two, each half can be split in two again, and so on, with `gaps` between windows. Every window of the workspace is on screen: nothing scrolls, nothing is parked off the side. Workspaces you are not on are hidden below the display as usual.

- **Switching.** `Alt+Shift+T` (`toggle-workspace-layout`) or `set-workspace-layout-scrolling` / `-dwindle`. Every window stays and the focused one keeps the focus. Going to dwindle builds the tree from the strip, left to right (a spiral: each window splits the previous one); going back gives one column per window, in the tree's order (a stacked column becomes one tile per window in dwindle and does not come back stacked).
- **New windows** split the focused window: side by side when its tile is wider than tall, stacked otherwise, and the new window takes the right (or bottom) half. A split keeps the shape it got when it first appeared, so resizing never flips the splits inside it. `dwindle-preselect-left` / `-right` / `-up` / `-down` choose the side (and the shape) for the next new window of the workspace; `dwindle-preselect-clear` drops the choice. A window that becomes floating or is minimized keeps its place in the tree; its neighbour takes the space until it comes back.
- **Closing** a window gives its space to its sibling.

Dwindle actions (they do nothing on a scrolling workspace):

| Action (config name) | Default | What it does |
| --- | --- | --- |
| `toggle-workspace-layout` | `Alt+Shift+T` | Scrolling to dwindle and back. |
| `set-workspace-layout-scrolling` / `set-workspace-layout-dwindle` | unbound | Choose the layout of the current workspace. |
| `dwindle-toggle-split` | unbound | Flip the split holding the focused window between side by side and stacked. |
| `dwindle-swap-split` | unbound | The two halves of that split trade places; each keeps its size. |
| `dwindle-balance` | `Alt+Shift+B` | Every split of the workspace back to half and half. |
| `dwindle-preselect-left` / `-right` / `-up` / `-down` | unbound | The next new window opens on that side of the focused one. Used once. |
| `dwindle-preselect-clear` | unbound | The next new window opens in the default place again. |

What the shared actions do on a dwindle workspace:

| Action | In dwindle |
| --- | --- |
| `focus-left` / `-right` / `-up` / `-down` | Focus the window next to the focused one on that side (the nearest tile that overlaps it). Nothing at the edge. |
| `move-column-left` / `-right`, `move-up` / `-down`, `consume-or-expel-window-left` / `-right`, `move-window-left` / `-right`, `swap-window-left` / `-right` | Trade tiles with the window on that side; focus stays on the moved window. At the edge nothing happens, except that `move-column-left` / `-right`, `move-up` / `-down` and `consume-or-expel-window-left` / `-right` with `move-crosses-monitor-at-edge` send the window to the display on that side. |
| `move-column-left-or-to-monitor-left` / `-right-or-to-monitor-right`, `focus-column-or-monitor-left` / `-right` | Trade tiles (or focus) inside the tree; from its left (right) edge, send the window to (or focus) the display on that side. |
| `focus-window-or-workspace-down` / `-up` | The tile below (above); from the bottom (top) edge, the workspace below (above). |
| `focus-column-first` / `focus-column-last` | The first / last window in the tree's order (the top-left tile and the innermost one of a spiral). |
| `set-column-width-plus` / `-minus` | Give the focused window's side of the nearest side-by-side split 10% more (less) of that split. Ratios stay between 5% and 95%. |
| `switch-preset-column-width` / `-back` | Set the focused window's share of the nearest side-by-side split to the next (previous) value of `preset-column-widths` (a fraction is a share of the split, points are measured against it). |
| `set-window-height-plus` / `-minus`, `switch-preset-window-height`, `reset-window-height` | The same on the nearest stacked split (`preset-window-heights`); reset makes it half and half. |
| `maximize-column` | Zoom: the focused window fills the area inside the padding, the others stay in their tiles behind it; again (or focusing another window, or closing it) restores the tiles. |
| `fullscreen` | As in the strip: the window covers the display, the other tiles are parked, and it returns to its tile when you leave fullscreen or focus another window. |
| Workspace, monitor, floating and overview actions | As in the strip. A dwindle "column" is one window, so `move-column-to-workspace*` and `move-column-to-monitor-*` move the focused window; in a dwindle target it splits that workspace's focused window. |
| `center-column`, `center-visible-columns`, `expand-column-to-available-width`, `move-column-to-first` / `-last` | Nothing (every tile is on screen and there are no stacked columns). |

`gio focus` and `gio move` follow the tree the same way.

Limits: learned minimum sizes and rule `min-width` / `max-width` apply to the strip only; an app that cannot shrink to its tile overlaps its neighbour. Tabbed or grouped tiles (OmniWM's tile groups) and moving a window to the root are not implemented.

## Configuration reference

**File:** `~/.config/gio/config.toml`. Created from a commented template by `GioCLI setup`, **Diagnostics > Open Config File**, or the first edit in a Settings section. Changes apply with `gio reload`, **Diagnostics > Reload Config**, or automatically after **Apply** in Settings.

### Format rules

Gio parses a strict **subset of TOML**:

- Tables `[layout]`, `[behavior]`, `[animations]`, `[dwindle]`, `[focus]`, `[focus-ring]`, `[logging]`, `[keybindings]`, the per-animation tables `[animations.<name>]`, and array tables `[[workspace]]` and `[[window-rules]]`.
- `key = value` with double-quoted strings, integers, decimals, `true`/`false`, and flat lists of numbers like `[0.33, 0.5, 800]` (a trailing comma is tolerated; nested lists are not).
- `#` comments outside quotes. Keys may be quoted (`"Alt+H" = ...`).
- No escapes in strings, no multi-line values, no inline tables.

Validation outcomes:

| Problem | Result |
| --- | --- |
| Syntax error, key outside any table, wrong value type, value out of range, unknown action name, unparsable hotkey, rule without a valid `app` | **Error.** The whole file is rejected, **defaults are used**, and every message (with its line number) is shown in the app (**Overview**, **Diagnostics**) and returned by `gio reload`. |
| Unknown table or unknown key inside a known table | **Warning.** Ignored, everything else applies (forward compatibility). |
| `animations.duration-ms` outside 0 to 1000, `animations.spring-damping-ratio` outside 0.2 to 3, `animations.spring-stiffness` outside 100 to 3000, `focus-ring.width` outside 0 to 20, `focus.dim-strength` outside 0.0 to 0.5 | **Warning.** Clamped into range. |
| `layout.default-layout`, `[[workspace]] layout` other than `"scrolling"` / `"dwindle"`, `dwindle.default-split-ratio` outside 0.1 to 1.9, `dwindle.split-width-multiplier` outside 0.1 to 10 (or not a number) | **Warning.** The default is kept and the rest of the file applies (DW-03: a layout typo never rejects the file). |
| Missing file | Silent defaults (first run). |

An invalid config never stops the window manager.

### `[layout]`

| Key | Type | Default | Validation and meaning |
| --- | --- | --- | --- |
| `gaps` | number (points) | `8` | Non-negative. Space between columns and between windows in a column. |
| `padding` | number (points) | `8` | Non-negative. Outer margin around the strip inside the usable display area. |
| `fullscreen-gap` | number (points) | value of `gaps` | `0` to `64`, otherwise an error. Inset kept around a fullscreen window (`Alt+Shift+F`) on every side, below the menu bar. `0` is edge to edge. Applies live on reload, also to a window that is already fullscreen. Settings > Layout has a matching control. |
| `default-column-width` | number | `0.5` | Positive. `<= 1` is a **proportion** of the strip (Niri semantics, `p * (viewport - 2*padding + gap) - gap`, so two `0.5` columns fill the screen exactly). `> 1` is an absolute width in points. Columns are never narrower than 200 pt. |
| `preset-column-widths` | list of numbers | `[0.33333, 0.5, 0.66667]` | Non-empty list of positive numbers, same `<= 1` proportion vs points rule. `Alt+R` cycles through them. |
| `preset-window-heights` | list of numbers | `[0.33333, 0.5, 0.66667]` | Non-empty list of positive numbers. `<= 1` is a proportion of the usable display height (same formula as widths, `p * (height - 2*padding + gap) - gap`, so two `0.5` windows fill a column exactly); `> 1` is points. `Alt+Shift+R` cycles the focused window of a stacked column through them, clamped so every window keeps 100 pt. Settings > Layout > **Window Height** edits them as chips. |
| `center-focused-column` | `"never"`, `"always"`, `"on-overflow"` | `"never"` | Niri semantics (and Niri's default), applied on keyboard/IPC focus changes only. `never` scrolls minimally (the column stops at the layout padding, never flush with the screen edge; a column already in view just takes focus, nothing moves); `always` centers the focused column; `on-overflow` centers only when it does not fit on screen together with the previously focused column (a neighbour already in view just takes focus, nothing moves; with columns too wide to fit in pairs, every focus change re-centers the strip). The old boolean still parses (`true` = `always`, `false` = `never`). Any other value is an error and the default applies. |
| `maximize-single-window` | bool | `true` | A workspace whose only tiled window is alone shows it at the full strip width, the same frame `Alt+F` gives (floating windows do not count). The column keeps its own width: a second window (or a second window stacked in the column) brings the normal widths back. While a window is alone, width actions (`Alt+R`, `Alt+Minus`/`Alt+Equal`, `Alt+F`) change its stored width without a visible change. `false` keeps the column width. Settings > Layout > **Full width when alone**. |
| `always-center-single-column` | bool | `false` | A workspace with a single column (one window, or one stack) shows it in the middle of the display instead of at the left padding, whatever `center-focused-column` says (niri's option of the same name). A column too wide to fit inside the padding stays at the padding. With `maximize-single-window` on, a lone window already fills the strip; the option matters for a lone stacked column or with `maximize-single-window = false`. Settings > Layout > **Center a lone column**. |
| `default-layout` | `"scrolling"`, `"dwindle"` | `"scrolling"` | Layout new workspaces start with (see [Dwindle layout](#dwindle-layout)). An empty workspace takes a changed value at once; a workspace with windows keeps its layout until you switch it (`Alt+Shift+T`). A named workspace with its own `layout` keeps that. Settings > Layout > Workspace Layout. |

### `[dwindle]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `default-split-ratio` | number | `1.0` | `0.1` to `1.9`. When a new window splits the focused one, the focused window keeps this share of the tile, times two (`1.0` half and half, `1.2` keeps 60%). Settings > Layout > **Dwindle split ratio**. |
| `split-width-multiplier` | number | `1.0` | `0.1` to `10`. A new split puts its halves side by side when the tile is at least this many times wider than tall, otherwise stacks them; above 1 favours stacking (Hyprland's `split_width_multiplier`). A split keeps the shape it got. Settings > Layout > **Dwindle width multiplier**. |

`smart-split` (Hyprland: the side follows the pointer) is not supported: Gio has no pointer position when a window opens. It warns; use `dwindle-preselect-*` instead.

### `[behavior]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `focus-follows-mouse` | bool | `false` | When the pointer rests about 100 ms over a visible tiled window, that window takes focus (activated and raised). It never scrolls the strip beyond the usual reveal of a partly hidden column, and is ignored while a mouse button is down, over Gio's own windows, popups, or windows Gio does not manage. |
| `mouse-follows-focus` | bool | `true` | After a keyboard or IPC focus change, the cursor jumps to the center of the focused window (unless it is already inside). Never after a click or hover focus. |
| `move-crosses-monitor-at-edge` | bool | `false` | Move Edge. The window move (`consume-or-expel-window-left` / `-right`, `move-up` / `-down`, `gio move`) from the workspace's edge (a lone window in the first / last column, or the top / bottom of its column) sends the window to the display on that side, stacked at the bottom of the column nearest the edge it enters by (moving left the target's last column, moving right its first, up or down its focused one; its own column in an empty or dwindle workspace), as OmniWM does. `move-column-left` / `move-column-right` at the first / last column send the column there, like `move-column-left-or-to-monitor-left` / `-right-or-to-monitor-right`: it lands as the target's last (moving left) or first (moving right) column. Focus follows. No display that way (one display): nothing moves. A non-boolean value is a config error, like the other `[behavior]` keys. Settings > Focus > Displays > **Move windows and columns across displays at the edge**. |

### `[animations]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Off makes every reflow instant. |
| `curve` | string | `"spring"` | `"spring"` (Niri-style) or `"ease-out"`. A spring keeps the speed of a move it interrupts, so rapid key presses flow instead of restarting. An unknown name warns and keeps the default. |
| `duration-ms` | number | `200` | Length of one `ease-out` animation. Rounded and clamped to `0...1000` with a warning. `0` is instant for both curves. |
| `spring-damping-ratio` | number | `1.0` | `0.2...3`. `1` settles without overshoot; lower values bounce. Clamped with a warning. |
| `spring-stiffness` | number | `800` | `100...3000`. Higher is faster. Clamped with a warning. A spring never runs longer than 1 s. |
| `resize` | string | `"never"` | How windows that grow (maximize, widen) behave during a move. `"adaptive"`: the window grows along with the motion when its app has proven it keeps up (cheap writes, few dropped frames, no recent size clamp) and no neighbour is in the way; other apps grow once at the end. `"always"`: skip the app check, still never overlap a neighbour. `"never"`: every grow happens once at the end. Shrinks always happen first. An unknown value warns and keeps the default. Gio learns each app over the first two motions, so a new app grows at the end at first. `gio logs` shows `sizeAnimated=N` in `anim done`. |
| `focused-grow` | string | `"start"` | When the focused window that grows (maximize, fullscreen, a wider preset) gets its final size. `"start"`: in the first frame of the motion, then only its position animates, so it is not cut while the neighbours slide away (it may overlap them briefly, it is in front). `"end"`: it grows once at the end like every other window. Only the window you just focused with the keyboard or CLI is affected; other windows follow `resize`. If `resize` already grows the window during the motion, that timing is kept. An unknown value warns and keeps the default. `gio logs` shows `grewAtStart=N` in `anim done`. |
| `native-zoom` | bool | `true` | Maximize (`Alt+F`) on a single-window column presses the app's own zoom, the same as double-clicking its title bar, instead of writing a new size: the app animates it in-process, so it does not wait to repaint (a brand-new size can take 300-750 ms to appear). The neighbours still animate; the zooming window is left alone until it settles. Gio waits up to 1.5 s for the zoom to settle (a busy app that answers the zoom late is not treated as a failure and its window is not written meanwhile), then writes the exact layout target once so the maximized window keeps the tiling gaps instead of covering the whole screen; it writes nothing only when the app's frame already equals the target within 2 pt. If the zoom cannot be pressed, changes nothing or never settles, the normal write is used. Toggling back presses the zoom again. Stacked columns, apps with no usable zoom button, `renderer = "snapshot"` and animations off use the normal write. `gio logs` shows `native zoom id= app= action= result=exact\|corrected\|fallback(reason[:axerror]) ms= settleMs= verified=`. Gio waits for a quiet period after the last size change (multi-stage zooms) and re-checks the window once after writing; if the app overwrote the gaps it writes them one more time (`native zoom reassert`). |
| `renderer` | string | `"snapshot"` | How motion is drawn. `"snapshot"` (default): the real windows move once, under an overlay that slides images of them at the display's refresh rate, so every app moves at the same speed however slowly it repaints. The overlay shows the real desktop behind the windows, their shadows, the focus ring and the dim, and comes down only once the windows that came into view have painted. Tradeoff: during the roughly 350 ms slide each window shows its content as of its last capture (Gio re-captures a window after you type in it, after it has been focused for a few seconds, after it changes size, and keeps images for every workspace). A window that changes size (maximize, width presets, consume/expel, dwindle splits) is never stretched: its content stays at its own size, cut off at the moving edge or next to a flat strip of its background colour, and dissolves within a few frames into its content at the new size when Gio has seen that size before. It needs the Screen Recording permission; until it is granted, or on macOS 13, Gio uses the Accessibility motion and logs `renderer effective=ax reason=screen-recording-missing`. A window Gio has never seen on screen since launch may use the Accessibility motion for its first motion. Clicking during a slide removes the overlay at once. Gio never asks for the permission at launch: use the "Request access" button in Overview or Diagnostics, then relaunch Gio because macOS usually applies a new grant only on the next launch. `"ax"`: move the real windows every frame through Accessibility, so content is always current, but slow apps (WhatsApp, Music, Xcode) move at their own pace. Every motion logs `anim done ... renderer=snapshot\|ax` (`snapshot` with `hitches=N`, `ax` with `missed=M` and `hitches=H`), so the renderers can be compared. Settings > Animations > Renderer switches it. Any other value warns and keeps the default. |

### `[logging]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `level` | string | `"info"` | Minimum severity written to `~/.config/gio/gio.log`: `trace`, `debug`, `info`, `warn`, `error`. Lines below it cost nothing. Use `"debug"` while troubleshooting (per-event hotkey/focus/reconcile lines), then go back. Applies on `gio reload`. The Logs section's **Log file level** picker writes this key and reloads. |

The file is written in batches and rotates at about 1 MB to `gio.log.1` (one backup kept); `gio logs` and the Logs section read the current file only. Gio and its guardian helper share the file: each batch is appended as whole lines in one write, so their lines never interleave mid-line, and only Gio rotates it.

### `[focus]`

Which focus indicator runs.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `indicator` | string | `"dim"` | `"dim"` darkens the other visible tiled windows while nothing moves, so the focused window stays lit. `"ring"` draws the outline configured in `[focus-ring]`. `"none"` draws nothing. Anything else is an error. |
| `dim-strength` | number | `0.15` | Opacity of the black dim over unfocused windows, clamped to `0.0...0.5` with a warning. Dark mode uses 80% of it. |

The dim is drawn by click-through overlays (one per display, just above ordinary windows and below floating panels, menus and the Dock) and never takes focus. Only tiled windows are dimmed; floating windows, popovers and any window in front of a dimmed one (other apps included) stay untouched, and so do minimized, parked and off-screen windows. It fades out (80 ms) when a motion, workspace switch, native zoom or window drag starts and fades back in (150 ms) once everything settled; with Reduce Motion it appears and disappears without a fade. Settings, Layout, Focus indicator has a Dim / Ring / None control and a strength slider.

### `[focus-ring]`

Used when `[focus] indicator = "ring"`. A rounded outline around the focused window, drawn by a click-through overlay that never takes focus. It follows the window while it animates.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Off removes the ring. |
| `width` | number | `4` | Thickness in points, rounded and clamped to `0...20` with a warning. `0` hides the ring. |
| `hide-when-maximized` | bool | `true` | No ring on a maximized column (`Alt+F`) or a fullscreen window. `false` shows it again (in fullscreen only when `layout.fullscreen-gap` is at least the ring `width`). Also a toggle under Settings, Layout, Focus ring. |
| `active-color` | string | `"#7fc8ff"` | Hex color (`#RGB` or `#RRGGBB`); anything else is an error. When unset the active theme's active border color is used if it defines one, else the Niri blue. |

The ring is hidden when nothing is focused, the focused window is minimized, maximized or fullscreen (`hide-when-maximized`), fullscreen without room for it (it shows when `layout.fullscreen-gap` is at least the ring `width`) or off-screen (parked, or on a workspace no display shows), and while Gio itself is the active app (its main window or launcher). Floating windows get the ring too. The ring sits outside the window, so a width larger than `gaps` overlaps the neighbouring columns' edges.

### `[gestures]`

Trackpad swipes (see [Trackpad gestures](#trackpad-gestures)). Unlike the other tables, a bad value here only warns and keeps that key's default, so a gesture typo never sets the rest of the file aside. Settings, Focus, **Trackpad Gestures** edits the same keys.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `scroll` | bool | `true` | A horizontal swipe scrolls the strip of the display under the pointer: it follows the fingers, and on release it springs to a column edge with the speed of the swipe. |
| `scroll-fingers` | number | `3` | Fingers for the scroll: `3`, `4` or `5`. Two fingers are the system's own scrolling and are not offered. |
| `scroll-sensitivity` | number | `1.0` | Strip travel for a swipe across the whole trackpad, in screen widths. Clamped to `0.1...5.0` with a warning. |
| `natural` | bool | `true` | Content follows the fingers, like macOS natural scrolling: swipe left to see the columns on the right, swipe up to go to the workspace below. `false` inverts the scroll and the workspace swipe. |
| `workspace-swipe` | bool | `true` | A vertical swipe switches to the workspace above or below, one per swipe (`focus-workspace-up` / `-down`). |
| `workspace-fingers` | number | `3` | Fingers for the workspace swipe: `3`, `4` or `5`. May equal `scroll-fingers` (the direction tells them apart). |
| `overview` | bool | `false` | A swipe up opens or closes the workspace overview (like `Alt+O`). Off by default because macOS Mission Control already uses a four-finger swipe up. |
| `overview-fingers` | number | `4` | Fingers for the overview swipe: `3`, `4` or `5`. Must differ from `workspace-fingers` while both are on (both swipe vertically): otherwise the overview is turned off with a warning. |

### Custom key bindings

The `[keybindings]` table maps a combo to an action name: `"Alt+H" = "focus-left"`.

- **Combo syntax:** one or more modifiers plus one key, joined by `+`. Modifiers (case-insensitive): `ctrl`/`control`, `alt`/`option`, `shift`, `cmd`/`command`. At least one modifier is required. Keys are case-insensitive and come from one list: `A`-`Z`, `0`-`9`, `F1`-`F12`, `Left`, `Right`, `Up`, `Down`, `Tab`, `Return` (`Enter`), `Escape` (`Esc`), `Space`, `Delete` (`Backspace`), `Home`, `End`, `PageUp` (`PgUp`), `PageDown` (`PgDn`), and punctuation `Grave` (`` ` ``), `Comma` (`,`), `Period` (`.`), `Slash` (`/`), `Semicolon` (`;`), `Quote` (`'`), `Backslash` (`\`), `Minus` (`-`), `Equal` (`=`), `BracketLeft` (`[`), `BracketRight` (`]`).
- **Action names:** `focus-left`, `focus-right`, `focus-up`, `focus-down`, `move-column-left`, `move-column-right`, `move-window-left`, `move-window-right` (aliases `move-left`, `move-right`), `move-up`, `move-down`, `workspace N`, `move-to-workspace N` (write them as `"workspace 3"`; use N from 1 to 9, other values do nothing), `focus-workspace-down`, `focus-workspace-up`, `move-window-to-workspace-down`, `move-window-to-workspace-up`, `toggle-floating` (alias `toggle-window-floating`), `fullscreen` (alias `fullscreen-window`), `switch-preset-column-width`, `set-column-width-minus`, `set-column-width-plus`, `maximize-column`, `center-column`, `consume-or-expel-window-left`, `consume-or-expel-window-right`, `switch-preset-window-height`, `set-window-height-minus`, `set-window-height-plus`, `reset-window-height`, `focus-column-first`, `focus-column-last`, `move-column-to-first`, `move-column-to-last`, `swap-window-left`, `swap-window-right`, `move-column-to-workspace N` (like `move-to-workspace N`), `move-column-to-workspace-down`, `move-column-to-workspace-up`, `focus-workspace-previous`, `move-workspace-down`, `move-workspace-up`, `focus-window-or-workspace-down`, `focus-window-or-workspace-up`, `switch-preset-column-width-back`, `expand-column-to-available-width`, `center-visible-columns`, `move-column-left-or-to-monitor-left`, `move-column-right-or-to-monitor-right`, `focus-column-or-monitor-left`, `focus-column-or-monitor-right` (these four are unbound by default), and per direction (`left`, `right`, `up`, `down`) `focus-monitor-<direction>`, `move-column-to-monitor-<direction>`, `move-window-to-monitor-<direction>`, `move-workspace-to-monitor-<direction>` (the last two are unbound by default, for example `"Ctrl+Alt+Cmd+L" = "move-workspace-to-monitor-right"`).
- **Bindings are additive.** Config entries are layered over the defaults: a config entry binds a combo (replacing the default action of that exact combo). Default bindings stay active unless you reuse their combo or unbind it.
- **Unbind with `"none"`.** `"Alt+C" = "none"` makes the combo do nothing, defaults included (Alt+C no longer centers the column; every other default stays). For one combo the last line in the file wins, so `"none"` followed by an action binds it again. Shortcuts shows such a default under its action as **Removed**.
- **Unknown keys are rejected.** A binding on a key outside the list above (for example `Alt+F13`) is a config validation error (`unknown key 'F13' in hotkey ...`), never a binding that silently does nothing. Keys are matched on the ANSI virtual keycode, so the physical position wins on non-US layouts.
- `Alt+Space` (launcher) cannot be rebound or removed.
- **From the app.** Shortcuts edits these lines for you (see [Main window sections](#main-window-sections)): **Add** writes `"<combo>" = "<action>"` (taking the combo from another action is a **Replace**), **×** on a config-only binding deletes its line and on a default writes `"<combo>" = "none"`, and **Reset** deletes every line that changes that action so its defaults run again. Comments and unrelated lines are kept.

### `[[workspace]]`

A named workspace (Niri's named workspaces). Each block declares one; order in the file is their order in the stack.

| Key | Required | Values | Meaning |
| --- | --- | --- | --- |
| `name` | yes | non-empty string, unique | Shown in the Overview, menu bar and launcher; the target of a rule's `open-on-workspace`. |
| `icon` | no | SF Symbol name, e.g. `"globe"` | Shown next to the name by the desktop app. |
| `color` | no | hex color `"#RGB"` or `"#RRGGBB"` | Accent for the workspace in the desktop app. |
| `display` | no | `"main"` (default) or a display number `1`, `2`, ... | The display whose stack holds it. `1` is the main display (the one at the origin, with the menu bar in System Settings > Displays); the others are numbered by position, left to right (top to bottom when they line up vertically). A number with no such display connected falls back to the main display, and the workspace moves back when that display returns. |
| `layout` | no | `"scrolling"` or `"dwindle"` | The workspace's layout (unset: `[layout] default-layout`). Applied when the workspace is created or the key changes, so switching it at runtime (`Alt+Shift+T`) lasts until you edit this key. Settings > Workspaces > **Layout**. |

An empty or duplicate `name`, a bad `color` or a bad `display` is a config error. Unknown keys warn.

On a config reload (or **Apply** in the app) named workspaces are matched by name, so reordering keeps each one's windows. A new name is created empty. A name that disappears turns its workspace into an ordinary dynamic one in place: its windows stay, and it is removed once empty and not shown. Renaming is recognised by position: when the name at position N disappears and a new name appears at the same position N, the workspace is renamed and keeps its windows.

### `[[window-rules]]`

See [Window rules](#window-rules).

### Example

```toml
[layout]
gaps = 8
padding = 8
# fullscreen-gap = 8   # unset follows gaps; 0 is edge to edge
default-column-width = 0.5
preset-column-widths = [0.33333, 0.5, 0.66667]
preset-window-heights = [0.33333, 0.5, 0.66667]

[animations]
enabled = true
curve = "spring"
duration-ms = 200
spring-damping-ratio = 1.0
spring-stiffness = 800
resize = "never"
focused-grow = "start"
native-zoom = true
renderer = "snapshot"

[focus]
indicator = "dim"
dim-strength = 0.15

[focus-ring]
enabled = true
width = 4
hide-when-maximized = true
active-color = "#7fc8ff"

[logging]
level = "info"

[keybindings]
"Alt+Shift+R" = "switch-preset-column-width"

[[window-rules]]
app = "Calculator"
mode = "floating"

[[window-rules]]
app = "Notes"
workspace = 2

[[workspace]]
name = "Code"
icon = "chevron.left.forwardslash.chevron.right"

[[window-rules]]
bundle-id = "com.microsoft.VSCode"
open-on-workspace = "Code"
follow = "always"
```

## Window rules

A rule is a `[[window-rules]]` block. It needs at least one of `app`, `bundle-id` or `title`.

| Key | Required | Values | Meaning |
| --- | --- | --- | --- |
| `app` | one of `app`, `bundle-id`, `title` | non-empty string | **Exact** application name as macOS reports it (`localizedName`). No globs, no prefixes. |
| `bundle-id` | one of `app`, `bundle-id`, `title` | non-empty string, e.g. `"com.microsoft.VSCode"` | **Exact** bundle identifier. Preferred over `app`: when the window's bundle identifier is known, a rule with `bundle-id` matches only by it; when it is unknown, the rule falls back to its `app` name (if any). |
| `title` | one of `app`, `bundle-id`, `title` | regular expression string, e.g. `"^Picture in Picture$"` | Matches when the pattern is found in the window title, **case-insensitive** (start the pattern with `(?-i)` to make it case-sensitive; use `^...$` for the whole title). With `app` or `bundle-id` both must match; alone it matches any app. A window without a title never matches a `title` rule. The string is taken verbatim (`\d` stays `\d`); a pattern cannot contain a double quote. An invalid pattern is a config error that quotes the pattern. |
| `mode` | no | `"tiled"`, `"floating"`, `"fullscreen"` | Force the window's mode. |
| `workspace` | no | integer `1` to `9` | Put the window on this position of the focused display's workspace stack (of the `open-on-display` display, when set) when it appears. A number past the end of the stack uses the empty workspace at the bottom (intermediate empty workspaces cannot exist), so `workspace = 3` on a two-workspace stack lands on the bottom empty one. |
| `open-on-workspace` | no | a `[[workspace]]` name | Put the window on that named workspace when it appears. Wins over `workspace` when both are set (with a warning). A name no `[[workspace]]` declares is a warning and the rule keeps its other keys. |
| `follow` | no | `"when-active"` (default), `"always"`, `"never"` | With `open-on-workspace`: whether Gio also takes you there. `when-active` follows when the app is frontmost as its window appears, when you launched the app within the last 3 seconds, or when the app becomes active within 1.5 seconds after its window was placed (unless you switched workspace or focus in the meantime, or the window closed); any other window that appears in the background goes there silently. |
| `default-column-width` | no | positive number | The new window's column width, with the `[layout]` key's semantics: a fraction of the strip when `<= 1`, points above. Unset: the layout default. |
| `open-maximized` | no | `true` / `false` (default) | The new window's column opens maximized, exactly the `Alt+F` state: `Alt+F` then restores `default-column-width` (or the layout default). |
| `open-on-display` | no | display number `1`, `2`, ... | Open on that display's shown workspace. Numbered like `[[workspace]] display`: `1` is the main display, the others by position. With `open-on-workspace`, the named workspace wins only when it lives on that display. A display that is not connected falls back to the focused display. |
| `open-focused` | no | `true` (default) / `false` | `false`: the window joins its workspace without becoming its focused window, and `follow` never takes you anywhere. |
| `min-width`, `max-width` | no | points, a number above `1` | Clamp the width of the window's column (in a stacked column the largest minimum and the smallest maximum apply; a minimum wider than the screen stops at the screen). The app's own minimum still wins: a window that refuses to get narrower keeps the width it needs. |

Behavior:

- **First matching rule wins, entirely.** Later rules never merge, so one window has one verdict, readable top to bottom.
- Rules apply **when a window first appears** (and to the windows found when Gio starts). Some apps (Chrome, Electron apps) show a window before giving it a title: a window that appears **without a title** is checked **once more** when its title first arrives, within 1 second of appearing. If a `title` rule wins then, Gio applies its mode, workspace or display, width, maximized and width limits; it never focuses the window, never switches workspace and never follows. Later title changes are not checked again.
- `open-on-workspace` sends the window to that named workspace, on whichever display holds it. Following (`follow`) only happens for windows that appear while Gio runs (a new window, or the windows of an app you just launched), never for the windows Gio finds at startup or on a rescan. A minimized window never takes you anywhere. `floating` and the other rule keys still apply.
- `open-focused = false` only governs Gio: the app itself may still bring its new window to the front (macOS lets apps do that), and Gio then follows the real focus as it does for any click.
- On reload (or **Apply** in the app), float rules are re-evaluated against each window's **current** title: a newly matching `floating` rule floats the window (reason `rule`), and a window whose rule no longer matches goes back to tiled. Windows floated by admission (dialog, panel, not resizable) or by the user are never promoted or relabeled. `min-width` / `max-width` re-apply to every window on reload. Workspace, display, `default-column-width`, `open-maximized` and `open-focused` are **not** re-applied: they only shape the window as it opens.
- A `tiled` rule does not override admission: a fixed-size window still floats.
- An invalid rule (none of `app`, `bundle-id`, `title`; an invalid `title` pattern; bad `mode`; workspace outside 1 to 9; bad `follow`; a non-positive width; a non-boolean `open-maximized` / `open-focused`; a display number below 1; a `min-width` / `max-width` of 1 or less, or a `min-width` above `max-width`) is a config error and rejects the whole file.
- Window titles are matched in memory only; they are never written to the log.

## Desktop app

`Gio.app` is one process: menu bar item, a main window and the launcher. It shows a Dock icon only while the main window is visible. Closing the window hides it; Gio keeps tiling from the menu bar.

**Open at Login.** Overview > Status has an **Open at Login** switch, and so does the last step of the first-run guide (**Keys to Know**). It registers this copy of `Gio.app` as a macOS login item (the same list as System Settings > General > Login Items, where you can also turn it off); nothing is written to `config.toml`. If macOS asks for approval, the row says so and offers **Open Login Items…**. A login launch starts quietly in the menu bar without opening the main window, unless Accessibility is missing (then the window opens so you can see why nothing tiles). The item points at the app where it was turned on: if you move `Gio.app` (for example into `/Applications`), turn the switch off and on again from the new copy. Under `swift run` the switch is disabled (no app bundle).

### Main window sections

| Section | What it shows or does |
| --- | --- |
| **Overview** | An **Updates** card at the bottom (version, status, Check Now, Update and Restart, release notes; see [Updates](#updates)). Named workspaces appear with their icon, color and `1 · Code` title in the workspace pills, the live strip header and the window list headers (dynamic ones keep `Workspace N`). Session status, Accessibility permission (with a **Request Access** button), Screen Recording permission (with a **Request access** button and a relaunch hint); in the first-run guide, once you have requested Screen Recording the step offers **Relaunch Gio** and reopens on that step after the restart, config summary and any config messages, display and workspace lines, and every managed window with its application, title, workspace and state (tiled, floating with reason, minimized, hidden). Refreshes every 3 s while the window is visible (nothing runs when it is closed to the menu bar). |
| **Shortcuts** | Every action grouped by category (Focus, Move, Columns, Windows, Workspaces, Monitors, App) with its current bindings, description and source (a `config` tag when `config.toml` changes it; defaults switched off are listed as **Removed**), search (`Cmd+F`), category chips and a Cheat Sheet layout. Per row: **Add** opens a recorder that captures the next key combo (Gio's own shortcuts are paused while it is open, so a bound combo reaches it; **Esc** cancels; switching to another app or closing the window cancels too). The combo needs at least one modifier and a key from the list in [Custom key bindings](#custom-key-bindings); `Alt+Space` is refused (launcher). A combo another action uses shows which one and whether it is a default or from config, and **Replace** moves it. Workspace rows pick the workspace number in the recorder. **×** removes one binding (in long families such as `Alt+1…9`, the **−** menu lists them). **Reset** appears when config changes the action and restores its defaults. Each change is written to `config.toml` and reloaded at once with a toast (like Rules: there is no draft to apply). The launcher row is fixed. |
| **Workspaces** | Named workspaces as cards in config order (the order of `Alt+1`, `Alt+2`, ...). Create one with **New Workspace** (`Cmd+N`), or from the empty state with a template (Code, Browsers, Chat, Design: icon and color only, apps are yours to add). Per card: click the icon to pick an SF Symbol (curated grid with search; **Use Number** shows the position instead), pick a color (preset swatches or the color well), rename inline (a name must be non-empty and unique, case-insensitive), choose a **Display** (Main or Display N; shown with more than one display), and reorder by dragging the handle or with the up/down arrows. **Apps** lists the apps whose new windows open there: **Add App** opens a picker with running and installed apps (`/Applications`, `/System/Applications`, `~/Applications`, one folder deep; icons, search, multi-select). An app belongs to one workspace: picking one that another workspace holds moves it, and the picker says so before you confirm. Each app chip's menu sets **Follow** (When Active, Always, Never) or removes it. Deleting a workspace asks first; its windows move to a regular workspace. Edits stay unsaved until **Apply**, which writes `[[workspace]]` blocks and `[[window-rules]]` with `bundle-id`, `app`, `open-on-workspace` and `follow` (an app that already has a rule gets those keys on that rule, so an earlier rule never shadows a new one; removing an assignment keeps the rule when it still sets a mode) and reloads live. Renames update the rules that point at the workspace. |
| **Layout** | Gaps, padding, default width (fraction or points), preset widths (comma separated), preset window heights (the same chips, NC-08), the center-focused-column mode, the Focus toggles (in the **Focus** section: focus follows mouse, mouse follows focus, and under **Displays** the MM-06/NC-14 **Move windows and columns across displays at the edge**), the **Focus indicator** (Dim / Ring / None; Dim shows a strength slider) and, with Ring selected, the ring settings (enable, width, hide on maximized/fullscreen, and color: a native color picker, preset swatches, a hex field kept in sync and a live preview; the ring is always opaque, so there is no opacity control; Apply writes `active-color = "#rrggbb"` and the ring updates immediately). **Apply** patches `config.toml` in place and reloads live; **Revert** restores the form. Invalid values are explained inline and Apply stays disabled. |
| **Animations** | Enable toggle, curve, spring or duration controls and the Resize mode (Never, Adaptive, Always) and the Renderer (Snapshot, Accessibility). Apply and Revert as above. |
| **Rules** | List of window rules with Add, Edit and Delete. Same validation as the file. Each row shows the app (the bundle id, or **Any app** for a title-only rule), the title pattern, and badges for the mode, workspace (a rule with `open-on-workspace` shows the workspace name), width, maximized, display, **Opens unfocused** and width limits. The editor sets every key: app name, **Title** pattern (validated as you type), mode, workspace, **Display** (shown with more than one display, or when the rule already names one), **Take focus**, **Column width** (Default, Fraction or Points), **Open maximized** and **Width limits** (min and max points; empty means no limit). The Workspaces section leaves `title` rules alone: they appear and are edited only here. |
| **Logs** | Live tail (last 500 rows, current file only) of `~/.config/gio/gio.log` with text search, **Show** level chips (they only filter this view), pause, auto-scroll, **Copy Visible** and **Reveal Log File**. The **Log file level** picker in the header decides what Gio writes to the file (`[logging] level`): changing it writes `config.toml`, reloads and confirms with a toast. |
| **Diagnostics** | **Updates** card: the automatic check and beta switches and the GitHub token field (see [Updates](#updates)). Facts: version and build, session, Accessibility, Screen Recording, config path and validity, IPC socket, display count, log file path. Buttons: **Reload Config**, **Restore All Windows** (brings parked windows on screen without quitting; tiling stays on, so the next layout change parks them again), **Test snapshot capture** (debug: captures the visible windows once and shows the summary, latency included; needs Screen Recording), **Open Config File**, **Quit Gio**. |

Settings edits are text-level: unrelated lines, comments and ordering survive, the result must re-parse before it is written, and the write is atomic (temp file plus rename). If the existing file has parse errors, edits are refused until it is fixed. Known gap: editing a rule from the app drops comments inside that rule block.

### Menu bar item

Title `Gio` (or `workspace · windows`), pushed by the session when it changes; no polling. Menu: **Open Gio**, the workspace stack of each display (**Workspace N · windows**, check mark on the active one, only the focused display's rows switch; a named workspace shows its icon and name with its `Alt` number, for example **Code ⌥1 · 2 windows**, and the header reads `Code (1 of 4)`; the status item badge keeps the index), window and column counts, **Move Window to Display** (with two or more displays: one row per display, `N  name`, numbered like `display = N`; the display the focused window is on is checked; sends `move-window-to-display N`), **Reload Config**, **Preferences...** (opens the main window), **Launcher...**, **Update to vX.Y.Z…** while an update is available (see [Updates](#updates)), **Quit Gio**. With no session it shows `no session` and disables session actions. **Quit Gio** runs the normal shutdown, which restores parked windows.

## Launcher

`Alt+Space` opens a small panel. Type to filter installed apps (top-level `.app` bundles in `/Applications`, `~/Applications`, `/System/Applications`) and Gio's managed windows, then press Enter. Named workspaces of the focused display match by name: typing `code` offers **Go to workspace Code** (kind **Workspace**), which switches there through the same path as `gio workspace N` (so focus follows like the hotkey). Windows are listed as `App — Title` with a window icon and their workspace; minimized windows are left out.

| Input | Effect |
| --- | --- |
| text | Fuzzy match over app names and windows (prefix, then substring, then ordered subsequence; a window matches by app name, by title, or both, and a title-only match ranks one step below an app-name match). On an equal rank workspaces come first, then windows, then apps. Enter runs the best match, or click a row. |
| a window | Switches to its workspace if needed, scrolls it into view and gives it keyboard focus, like a focus hotkey (including `center-focused-column` and `mouse-follows-focus`). |
| `> <verb>` | Run a Gio command over IPC, for example `> workspace 2` or `> reload`. |
| `! <command>` | Run a shell command with `/bin/zsh -c`. |

## Workspace overview

`Alt+O` (or `gio overview`) covers the display you are on with a dimmed panel (the display holding the focused window, else the one under the cursor, else the focused display; it becomes the focused display, so `1`-`9` and clicks act there; the log says `overview display id=N reason=focusedWindow|cursor|focusedDisplay`) that shows every workspace of its stack as a row, top to bottom, like niri's overview. Each row draws the workspace's strip to scale: the frame is the screen (what the workspace shows when it is the display's), windows outside it are faded, and a strip wider than the screen shrinks to fit. Named workspaces show their icon and `1 · Code` title; the display's current workspace is marked **Current**.

Windows show a live thumbnail captured when the panel opens (parked windows included). Thumbnails need **Screen Recording** and macOS 14; without them each window shows its app icon on the app's color. Window titles appear only in the panel, never in the log.

| Input | Effect |
| --- | --- |
| Arrows or `H`/`J`/`K`/`L` | Left/right walk the row's windows (column by column, top to bottom); up/down move one workspace and land on the window in the same place on screen. An empty workspace is selected as a whole. |
| `Return` or click | Close the panel and go there: a window switches to its workspace and takes keyboard focus (like the launcher); an empty workspace (or a click on a row's screen frame) switches to the workspace like `Alt+N`. |
| `1` ... `9` | Go to that workspace of the stack. |
| `Esc`, `Alt+O`, a click on the background, or switching apps | Close without changing anything. |

The panel shows the stack as it was when it opened; floating windows are not drawn (they are not part of any strip).

## Trackpad gestures

Gio reads the fingers on the built-in trackpad and on Magic Trackpads (see [Private APIs](../README.md#private-apis)) and turns swipes into strip and workspace moves. Keys are in [`[gestures]`](#gestures); Settings, Focus, **Trackpad Gestures** edits them.

| Swipe (defaults) | Effect |
| --- | --- |
| Three fingers left or right | The strip of the display under the pointer follows the fingers, columns coming into view as they arrive. Lift: the strip keeps the swipe's speed, springs to the nearest column edge (a fast swipe travels further, never past the first or last column) and the column it lands on takes the focus: the furthest one fully visible in the direction you swiped, as in niri. Its window is raised like after `Alt+L`, without moving the pointer. |
| Three fingers up or down | One workspace down or up per swipe (`natural = true`: up shows the workspace below), like `focus-workspace-down` / `-up`. |
| Four fingers up (`overview = true`) | Opens or closes the workspace overview, like `Alt+O`. |

- **Natural direction.** With `natural = true` (default) the content follows the fingers, as with macOS natural scrolling. `false` inverts the scroll and the workspace swipe.
- **Cancelling.** Put a fourth finger down during a scroll, or click, and the strip goes back to where it was; nothing changes. A scroll on a workspace with a fullscreen window does nothing, and neither does a scroll on a **dwindle** workspace (it has no strip; its tiles already fill the display). The workspace swipe and the overview swipe work on dwindle workspaces as on any other.
- **Moves while scrolling.** On every frame each window that changed moves through its app's Accessibility lane (the latest frame wins, so a slow app skips frames instead of falling behind). On release the strip springs to its column from the release velocity, through Accessibility whatever the renderer: the snapshot renderer does not draw the scroll, the real windows follow the fingers.
- **Permissions.** Gio asks for nothing more than Accessibility. It reads the trackpad through MultitouchSupport and never intercepts scroll or gesture events. Not yet verified on every macOS version: if the log never shows `gestures first contact frame` after a three-finger swipe, allow Gio in System Settings > Privacy & Security > Input Monitoring and relaunch it.
- **macOS uses the same swipes.** By default macOS switches full-screen apps with three- and four-finger horizontal swipes and opens Mission Control with three- and four-finger vertical swipes (App Exposé, when on, swipes down; three-finger drag turns every three-finger swipe into a drag). Gio cannot block them, so both act on the same swipe. Gio reads those settings (`com.apple.AppleMultitouchTrackpad`, `com.apple.driver.AppleBluetoothMultitouch.trackpad`, `com.apple.dock`; read only, never written; a missing value counts as macOS's default) and warns about each of its enabled gestures macOS also performs, in **Diagnostics > Gestures**, the **Overview** status card and Settings, Focus, **Trackpad Gestures**, with the place to change it: System Settings > Trackpad > More Gestures > **Swipe between full-screen applications** (or **Swipe between pages**), **Mission Control** or **App Exposé**, or System Settings > Accessibility > Pointer Control > Trackpad Options > **Dragging style** for three-finger drag. Set them to four fingers or Off when Gio uses three, or move Gio's gestures to other finger counts (five fingers collide with no swipe). The settings are read again at most every 10 s while the app's window shows them, and on every config reload.
- **Log lines** (no titles): `gestures available=<bool> reason=<reason>` (`devices=N`, `config-off`, `no-trackpad`, `missing-symbols:<names>`), `gestures conflict=<gesture-fingers:system,...>` or `gestures conflict=none` (once, then on change; for example `gestures conflict=scroll-3:full-screen-swipe,workspace-swipe-3:mission-control`), `gestures first contact frame`, `gesture scroll begin display= fingers= offset= columns=`, `gesture scroll end offset= snap= column= velocity= focusChanged=`, `gesture scroll abandoned reason=mouse|cancelled`, `gesture swipe fingers= direction= action=`.

## Command line (`gio`)

The client is the SwiftPM executable target **`GioCLI`** (its usage text prints `gio`). It sends the arguments to the running app over `~/.config/gio/gio.sock`; parsing and execution happen in the app. Without arguments it prints the usage and exits 2; if no app is running it prints an error and exits 1.

```sh
swift run GioCLI status
# or use the built binary, for example:
.build/debug/GioCLI list-windows
```

| Verb | Effect |
| --- | --- |
| `gio reload` | Re-read `config.toml`; prints messages if any. |
| `gio restart` | Replies `restarting Gio session`, then Gio restores every window, releases its socket and lock, starts a fresh instance of itself (the app bundle, or the bare executable under `swift run`) and exits. The new instance waits up to about five seconds for the lock. Under `swift run` the new process is a child of the old one, so run it from a shell you keep open. |
| `gio list-windows` | One line per managed window: pid, app, title, frame, mode, reason, minimized. |
| `gio list-workspaces` | The workspace stack with column and window counts; the current one is marked `*` (with several displays each stack is headed `display=<id>`, other displays' active workspace is marked `+`). Named workspaces end with `name=<name>`. |
| `gio focus left\|right\|up\|down` | Move focus like `Alt+H/L/K/J`. |
| `gio move left\|right\|up\|down` | The window move, like `Alt+Shift+H/L/K/J` (NC-14; before it, left/right moved the column); with `move-crosses-monitor-at-edge`, from the workspace's edge it sends the window to the next display (`moved window to the display on the right`). (The built-in usage text prints `up/down`; the parser wants `up` or `down`.) |
| `gio workspace 1...9` | Focus the workspace at this position of the focused display's stack (past the end: the empty one at the bottom). |
| `gio overview` | Open or close the workspace overview, like `Alt+O`. |
| `gio move-window-to-display N` | Send the focused window, as its own column, to the workspace display N shows (`1` is the main display, the others by position) and focus it. Also `> move-window-to-display N` in the launcher and the menu bar's **Move Window to Display**. |
| `gio layout info` | First line `layout=scrolling` or `layout=dwindle`. Scrolling: current workspace columns, viewport offset, focused column and column widths. Dwindle: window count, focused window, `tree=` (`(a \| b)` side by side, `(a / b)` stacked, `(a ~ b)` not laid out yet, the ratio after the sign when not 1, windows as `pid:id`), and any preselection or maximized window. |
| `gio layout toggle` / `gio layout scrolling` / `gio layout dwindle` | Switch the current workspace's layout (like `Alt+Shift+T` / `set-workspace-layout-*`), every window kept; prints `workspace N layout=...` or `layout unchanged`. Also `> layout toggle` in the launcher. The config is not changed. |
| `gio status` | JSON snapshot: `workspace` (index of the current workspace in its stack), `stacks` (per display: `display`, `focused`, `active`, and `workspaces` with `index`, `windows`, `columns`, `active`, `layout`, plus `name`, `icon` and `color` for named workspaces), `focusedWindow`, `columns`, `windows`, `modes`, `floatingWindows`, `minimizedWindows`, `layout` (current workspace) and `dwindle` (`null`, or `tree`, `windows`, `preselection`, `maximized` for a dwindle workspace). `gio list-workspaces` marks dwindle workspaces with `layout=dwindle`. Used by scripts and the menu bar. |
| `gio setup` | Checks permission, writes the config template if none exists, reports bindings and themes. |
| `gio doctor` | Health report: Accessibility, config, version, IPC, displays, recent errors. |
| `gio update` | Asks the running app to check GitHub for a newer release and prints the result (up to date, available, or why the check failed). See [Updates](#updates). |
| `gio update --install` | Checks if needed, then starts the download; replies once it started (or why this copy cannot update itself). Gio verifies the update, quits normally (windows restored) and reopens on the new version. |
| `gio uninstall` | Removes the socket and lock files only when no session holds the lock; keeps your config and themes. |
| `gio logs [--level trace\|debug\|info\|warn\|error]` | Print the log file, optionally at or above a level. |
| `gio help` | Usage. |

Not every keyboard action has a CLI verb (for example column widths, maximize, fullscreen, the column move and center have none; consume/expel is `gio move left|right`).

## Updates

Gio updates itself from the GitHub releases of `ismaelosuna7824/gio` (the `GioUpdateRepository` key in the app's Info.plist).

| Where | What |
| --- | --- |
| **Overview > Updates** | The running version and the updater status: **Check Now**, **Update and Restart** (with a progress bar while downloading), **Release Notes…** (the release's notes in a sheet, with **Update and Restart** and **View on GitHub**). |
| Menu bar | **Update to vX.Y.Z…** appears while an update is available; it opens Gio with the release notes. |
| **Diagnostics > Updates** | **Automatically check for updates** (on by default), **Include beta versions** (off by default) and **GitHub token (only for private repositories)**. |
| `gio update`, `gio update --install` | The same check and install from a terminal (see the table above). |

**When Gio checks.** About 30 seconds after launch (skipped if a check ran in the last hour, so restarts do not repeat it) and then about once a day while it runs. The daily check is scheduled by macOS (`NSBackgroundActivityScheduler`), which picks a convenient moment within an hour; Gio keeps no timer of its own, so it stays idle at rest. Turning **Automatically check for updates** off stops both; **Check Now** and `gio update` always work.

**Betas.** Prereleases (tags like `v0.3.0-beta.1`) are offered only when **Include beta versions** is on, or when you already run a beta. Drafts are never offered.

**What happens on Update and Restart.**

1. Gio downloads `Gio-<version>.dmg` and `Gio-<version>.dmg.sha256` to a temporary folder and compares the SHA-256. A mismatch stops here.
2. It checks the disk image's own signature (an Apple-issued certificate with the same team and the same certificate name as this copy) before it opens the image at all.
3. It mounts the image read-only and hidden (`hdiutil attach -nobrowse -readonly`), and checks the `Gio.app` inside: its code signature must satisfy this copy's designated requirement, the same team (read from this copy's own signature) and the bundle identifier `dev.gio.windowmanager`, it must be signed with the Hardened Runtime, and its version must be the one announced. Anything else is refused and nothing is installed.
4. It copies the verified app into a new private folder next to the installed one (a hidden `.gio-update-XXXXXX`, readable only by you) without access lists or extended attributes, resets its permissions (yours to write, everyone else's to read only), checks that copy's signature again and detaches the image.
5. It starts a small helper script and quits through the normal path (every window back on screen, the recovery helper told the exit was clean). The helper waits for Gio and the recovery helper to exit, moves the old app into its own private folder, puts the new one in place, checks the new app's signature once more and restores the old one if any step fails, then removes the quarantine flag and opens Gio again. It writes what it did to `~/Library/Logs/Gio/update.log` (paths and steps only).

Because the new version is signed with the same identity, Accessibility and Screen Recording stay granted.

**When Gio only notifies.** A copy that cannot replace itself still checks and shows the new version, with **Open Release Page** instead of **Update and Restart**: a development build (version `0.0.0-dev` or `<tag>+dev`, including anything run from Xcode's DerivedData or a `.build` folder), an ad-hoc signed copy, a copy macOS runs from a temporary location (App Translocation, after opening it straight from Downloads or the DMG) or from a read-only folder. Move `Gio.app` to `/Applications` and open it from there.

**Private repository.** While the repository is private, GitHub answers "not found" without a token; the status then says the repository is private or not found. Paste a GitHub token with read access to the repository's contents in **Diagnostics > Updates** and choose **Save**: it goes to your Keychain (item `dev.gio.windowmanager.update-token`) and is never shown again, logged or written to `config.toml`. **Clear** removes it. The token is only ever sent to `https://api.github.com`: Gio downloads assets through the GitHub API and drops the token on any redirect away from it (GitHub's file storage included). A fine-grained token limited to **Contents: Read-only** on this one repository is enough.

GitHub allows 60 unauthenticated requests per hour; Gio sends `If-None-Match`, so an unchanged release list does not count.

## Recovery if Gio dies

Gio starts a small helper (a second `Gio --guardian` process, no icon or window). If Gio is killed (Force Quit, `kill -9`, Xcode Stop, a crash), the helper brings parked windows back on screen within about a second and exits; the log shows `guardian restore applied=N`. It needs the same Accessibility permission as Gio. If it could not run, use `swift run gio-poc restore` or start Gio again.

## `gio-poc`

`gio-poc` is the Accessibility proof-of-concept tool (`swift run gio-poc <verb>`). It talks to Accessibility directly, needs Accessibility permission for the terminal or tool that runs it, and does **not** go through the running app. Window indices are positional within one fresh enumeration per call.

| Verb | Effect |
| --- | --- |
| `list-windows` | Print discovered windows and the skipped count. |
| `focus <index>` | Focus that window. |
| `move <index> <x> <y>` | Move a window. |
| `resize <index> <width> <height>` | Resize a window (positive sizes only). |
| `tile` | One-shot placement of one column per window on the main display. **Do not run against a live desktop while Gio is running**: it competes with the session. |
| `restore` | Bring parked or off-screen windows fully back on screen. Use after Gio was killed (normally the guardian does this for you; see below). |
| `events` | Print window and app events until interrupted. |
| `help` | Usage. |

Shared Xcode schemes in `Gio.xcworkspace`: `gio-poc-list`, `gio-poc-tile`, `gio-poc-restore` (each runs the matching verb) and `gio-doctor` (runs `doctor`).
