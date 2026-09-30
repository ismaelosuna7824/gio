# User guide

How to use Gio day to day: shortcuts, configuration, window rules, the desktop app and the command line. Everything here is derived from `defaultHotkeyBindings`, `ShortcutCatalog`, the config parser and the command grammar in the source.

Contents: [Concepts](#concepts) · [Shortcuts](#default-shortcuts) · [Config](#configuration-reference) · [Rules](#window-rules) · [Desktop app](#desktop-app) · [Launcher](#launcher) · [CLI](#command-line-gio) · [gio-poc](#gio-poc)

## Concepts

- **Strip and viewport.** Each workspace is a horizontal strip of **columns**. A column stacks one or more windows vertically. The display is a viewport onto the strip and scrolls to keep the focused column visible.
- **Workspaces.** Niri-style dynamic vertical stack, one per display. You start with one empty workspace. Putting a window in the last (empty) workspace opens a new empty one below it, so there is always exactly one empty workspace at the bottom. An empty workspace you are not on is removed: leave it and it disappears, and the indices below it shift up. Windows are never lost when a workspace disappears (it only ever disappears when it is empty), and a display that is unplugged hands its windows to a remaining display's stack. `Alt+1` to `Alt+9` address the workspace at that position in the focused display's stack; a number past the end of the stack goes to the empty workspace at the bottom. Windows of workspaces that no display shows are hidden off the bottom corner of the display. Every switch, up or down, animates vertically through the bottom edge because macOS cannot place windows above the menu bar.
- **Named workspaces.** Each `[[workspace]]` in the config is a named workspace. It always exists, even empty (it is never removed when you leave it), and named workspaces come first in their display's stack in config order, so `Alt+1` is the first one; dynamic workspaces follow them with the rules above (the empty one at the bottom is always dynamic). On a display that shows an empty dynamic workspace when named ones first appear (at startup), Gio opens on the first named one. Window rules with `open-on-workspace` send an app's new windows there (see [Window rules](#window-rules)). Without `[[workspace]]` nothing changes.
- **Modes.** A window is `tiled` (in the strip), `floating` (managed but outside the strip, keeps its own frame) or `fullscreen` (Gio's layout mode filling the display under the menu bar with a small gap around it, see `fullscreen-gap`; not a native macOS fullscreen Space).
- **Alt** means the **Option** key.

## Default shortcuts

Shortcuts are global while Gio runs and Accessibility permission is granted. A bound combo is swallowed (the app never sees it); everything else passes through untouched. All shortcuts below except the launcher can be rebound in `[keybindings]`.

| Shortcut | Action (config name) | What it does |
| --- | --- | --- |
| `Alt+H` | `focus-left` | Focus the column to the left. |
| `Alt+L` | `focus-right` | Focus the column to the right. |
| `Alt+K` | `focus-up` | Focus the window above in the current column. |
| `Alt+J` | `focus-down` | Focus the window below in the current column. |
| `Alt+Shift+H` | `move-column-left` | Swap the focused window's column with the one on its left. The column keeps its windows and sizes; focus stays on the same window. |
| `Alt+Shift+L` | `move-column-right` | Swap the focused window's column with the one on its right. |
| `Alt+Shift+K` | `move-up` | Move the focused window up within its column. |
| `Alt+Shift+J` | `move-down` | Move the focused window down within its column. |
| `Alt+R` | `switch-preset-column-width` | Cycle the focused column through the preset widths (first preset wider than the current width, wrapping). |
| `Alt+Minus` | `set-column-width-minus` | Make the focused column 10% narrower (clamped between the minimum width of 200 pt and the full strip). |
| `Alt+Equal` | `set-column-width-plus` | Make the focused column 10% wider. |
| `Alt+F` | `maximize-column` | Make the focused column fill the display width; press again to restore the previous width. |
| `Alt+C` | `center-column` | Scroll the view so the focused column is centered (clamped at the strip edges). |
| `Alt+[` (`Alt+BracketLeft`) | `consume-or-expel-window-left` | Pull the window into the left column, or push it out into its own column. |
| `Alt+]` (`Alt+BracketRight`) | `consume-or-expel-window-right` | Same, to the right. |
| `Alt+Shift+Space` | `toggle-floating` | Switch the focused window between tiled and floating. |
| `Alt+Shift+F` | `fullscreen` | Toggle fullscreen for the focused window; focusing another window restores the layout. |
| `Alt+U` | `focus-workspace-down` | Focus the workspace below in this display's stack (stops at the empty one at the bottom). |
| `Alt+I` | `focus-workspace-up` | Focus the workspace above. |
| `Alt+Shift+U` | `move-window-to-workspace-down` | Send the focused window one workspace down and follow it. From the last workspace with windows it lands in the empty one at the bottom, which opens a new empty workspace below. |
| `Alt+Shift+I` | `move-window-to-workspace-up` | Send the focused window one workspace up and follow it. |
| `Alt+1` ... `Alt+9` | `workspace N` | Focus the workspace at position N of this display's stack; past the end goes to the empty one at the bottom. |
| `Alt+Shift+1` ... `Alt+Shift+9` | `move-to-workspace N` | Send the focused window to position N (past the end: the empty one at the bottom). Focus stays where it was. |
| `Alt+Space` | (launcher, fixed) | Summon the launcher panel. Handled by the app before the action table; not configurable. |

That is 39 default action bindings plus the launcher. The **Shortcuts** section of the app lists the same table live, with the source of each binding (`default` or `config`).

Notes:

- `move-column-left`/`move-column-right` swap whole columns (a no-op at the strip edge); `move-up`/`move-down` reorder inside a column. To stack a window into a neighbour or unstack it, use `consume-or-expel-window-left/right` (`Alt+[` / `Alt+]`). The older `move-window-left`/`move-window-right` (alias `move-left`/`move-right`, append the window to the neighbouring column) are still valid config names but are unbound by default. `gio move left|right` swaps columns like the hotkeys.
- Shrink/grow always end as a proportion of the display, so the column adapts across displays.
- Fullscreen parks every tiled window where its column already is, so leaving fullscreen finds the strip unchanged.
- Focus, move, workspace, consume/expel and fullscreen actions also move macOS keyboard focus to the target window (right away, at the start of the animation; the end of the animation only re-asserts it if focus drifted). Rapid key presses during an animation merge into one retarget per display frame. Sizing, centering and floating actions leave focus alone, and so do clicks and window events.

## Configuration reference

**File:** `~/.config/gio/config.toml`. Created from a commented template by `GioCLI setup`, **Diagnostics > Open Config File**, or the first edit in a Settings section. Changes apply with `gio reload`, **Diagnostics > Reload Config**, or automatically after **Apply** in Settings.

### Format rules

Gio parses a strict **subset of TOML**:

- Tables `[layout]`, `[behavior]`, `[animations]`, `[focus]`, `[focus-ring]`, `[logging]`, `[keybindings]`, the per-animation tables `[animations.<name>]`, and array tables `[[workspace]]` and `[[window-rules]]`.
- `key = value` with double-quoted strings, integers, decimals, `true`/`false`, and flat lists of numbers like `[0.33, 0.5, 800]` (a trailing comma is tolerated; nested lists are not).
- `#` comments outside quotes. Keys may be quoted (`"Alt+H" = ...`).
- No escapes in strings, no multi-line values, no inline tables.

Validation outcomes:

| Problem | Result |
| --- | --- |
| Syntax error, key outside any table, wrong value type, value out of range, unknown action name, unparsable hotkey, rule without a valid `app` | **Error.** The whole file is rejected, **defaults are used**, and every message (with its line number) is shown in the app (**Overview**, **Diagnostics**) and returned by `gio reload`. |
| Unknown table or unknown key inside a known table | **Warning.** Ignored, everything else applies (forward compatibility). |
| `animations.duration-ms` outside 0 to 1000, `animations.spring-damping-ratio` outside 0.2 to 3, `animations.spring-stiffness` outside 100 to 3000, `focus-ring.width` outside 0 to 20, `focus.dim-strength` outside 0.0 to 0.5 | **Warning.** Clamped into range. |
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
| `center-focused-column` | `"never"`, `"always"`, `"on-overflow"` | `"never"` | Niri semantics, applied on keyboard/IPC focus changes only. `never` scrolls minimally; `always` centers the focused column; `on-overflow` centers only when it does not fit on screen together with the previously focused column. The old boolean still parses (`true` = `always`, `false` = `never`). Any other value is an error and the default applies. |

### `[behavior]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `focus-follows-mouse` | bool | `false` | When the pointer rests about 100 ms over a visible tiled window, that window takes focus (activated and raised). It never scrolls the strip beyond the usual reveal of a partly hidden column, and is ignored while a mouse button is down, over Gio's own windows, popups, or windows Gio does not manage. |
| `mouse-follows-focus` | bool | `true` | After a keyboard or IPC focus change, the cursor jumps to the center of the focused window (unless it is already inside). Never after a click or hover focus. |

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
| `renderer` | string | `"ax"` | How motion is drawn. `"ax"` (default): always move the real windows through Accessibility, so content is always live. `"snapshot"` (experimental; can flicker: the backdrop is the wallpaper file, without desktop icons, and the focus ring hides during the flight): animate window images in a GPU overlay (Screen Recording permission required; until it is granted, or in a build without it, Gio uses the Accessibility motion and logs `renderer effective=ax reason=screen-recording-missing`). With the snapshot renderer the real windows move once, under an overlay that animates their images: motion stays smooth even when an app repaints slowly. Tradeoff: during the roughly 350 ms flight the images show each window as of the last time Gio was idle, and windows Gio does not tile are hidden until it ends. Images are captured in the background after each settle (a moment after you stop, nothing runs while idle); the first motion after launch, or after a long pause, may use the Accessibility motion instead. Clicking during a flight removes the overlay at once. Gio never asks for the permission at launch: use the "Request access" button in Overview or Diagnostics, then relaunch Gio because macOS usually applies a new grant only on the next launch. An unknown value warns and keeps the default. |

### `[logging]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `level` | string | `"info"` | Minimum severity written to `~/.config/gio/gio.log`: `trace`, `debug`, `info`, `warn`, `error`. Lines below it cost nothing. Use `"debug"` while troubleshooting (per-event hotkey/focus/reconcile lines), then go back. Applies on `gio reload`. |

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

### Custom key bindings

The `[keybindings]` table maps a combo to an action name: `"Alt+H" = "focus-left"`.

- **Combo syntax:** one or more modifiers plus one key, joined by `+`. Modifiers (case-insensitive): `ctrl`/`control`, `alt`/`option`, `shift`, `cmd`/`command`. At least one modifier is required. Keys are case-insensitive and come from one list: `A`-`Z`, `0`-`9`, `F1`-`F12`, `Left`, `Right`, `Up`, `Down`, `Tab`, `Return` (`Enter`), `Escape` (`Esc`), `Space`, `Delete` (`Backspace`), `Home`, `End`, `PageUp` (`PgUp`), `PageDown` (`PgDn`), and punctuation `Grave` (`` ` ``), `Comma` (`,`), `Period` (`.`), `Slash` (`/`), `Semicolon` (`;`), `Quote` (`'`), `Backslash` (`\`), `Minus` (`-`), `Equal` (`=`), `BracketLeft` (`[`), `BracketRight` (`]`).
- **Action names:** `focus-left`, `focus-right`, `focus-up`, `focus-down`, `move-column-left`, `move-column-right`, `move-window-left`, `move-window-right` (aliases `move-left`, `move-right`), `move-up`, `move-down`, `workspace N`, `move-to-workspace N` (write them as `"workspace 3"`; use N from 1 to 9, other values do nothing), `focus-workspace-down`, `focus-workspace-up`, `move-window-to-workspace-down`, `move-window-to-workspace-up`, `toggle-floating` (alias `toggle-window-floating`), `fullscreen` (alias `fullscreen-window`), `switch-preset-column-width`, `set-column-width-minus`, `set-column-width-plus`, `maximize-column`, `center-column`, `consume-or-expel-window-left`, `consume-or-expel-window-right`.
- **Bindings are additive.** Config entries are layered over the defaults: a config entry binds a combo (replacing the default action of that exact combo). Default bindings stay active unless you reuse their combo for another action; there is no unbind syntax.
- **Unknown keys are rejected.** A binding on a key outside the list above (for example `Alt+F13`) is a config validation error (`unknown key 'F13' in hotkey ...`), never a binding that silently does nothing. Keys are matched on the ANSI virtual keycode, so the physical position wins on non-US layouts.
- `Alt+Space` (launcher) cannot be rebound or removed.

### `[[workspace]]`

A named workspace (Niri's named workspaces). Each block declares one; order in the file is their order in the stack.

| Key | Required | Values | Meaning |
| --- | --- | --- | --- |
| `name` | yes | non-empty string, unique | Shown in the Overview, menu bar and launcher; the target of a rule's `open-on-workspace`. |
| `icon` | no | SF Symbol name, e.g. `"globe"` | Shown next to the name by the desktop app. |
| `color` | no | hex color `"#RGB"` or `"#RRGGBB"` | Accent for the workspace in the desktop app. |
| `display` | no | `"main"` (default) or a display number `1`, `2`, ... | The display whose stack holds it. `1` is the main display (the one at the origin, with the menu bar in System Settings > Displays), the others follow in the order Gio registered them. A number with no such display connected falls back to the main display, and the workspace moves back when that display returns. |

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

[animations]
enabled = true
curve = "spring"
duration-ms = 200
spring-damping-ratio = 1.0
spring-stiffness = 800
resize = "never"
focused-grow = "start"
native-zoom = true
renderer = "ax"

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

A rule is a `[[window-rules]]` block:

| Key | Required | Values | Meaning |
| --- | --- | --- | --- |
| `app` | `app` or `bundle-id` | non-empty string | **Exact** application name as macOS reports it (`localizedName`). No globs, no prefixes. |
| `bundle-id` | `app` or `bundle-id` | non-empty string, e.g. `"com.microsoft.VSCode"` | **Exact** bundle identifier. Preferred over `app`: when the window's bundle identifier is known, a rule with `bundle-id` matches only by it; when it is unknown, the rule falls back to its `app` name (if any). |
| `mode` | no | `"tiled"`, `"floating"`, `"fullscreen"` | Force the window's mode. |
| `workspace` | no | integer `1` to `9` | Put the window on this position of the focused display's workspace stack when it appears. A number past the end of the stack uses the empty workspace at the bottom (intermediate empty workspaces cannot exist), so `workspace = 3` on a two-workspace stack lands on the bottom empty one. |
| `open-on-workspace` | no | a `[[workspace]]` name | Put the window on that named workspace when it appears. Wins over `workspace` when both are set (with a warning). A name no `[[workspace]]` declares is a warning and the rule keeps its other keys. |
| `follow` | no | `"when-active"` (default), `"always"`, `"never"` | With `open-on-workspace`: whether Gio also takes you there. `when-active` follows only when the app is frontmost as its window appears (you just launched or used it); a window that appears in the background goes there silently. |

Behavior:

- **First matching rule wins, entirely.** Later rules never merge, so one app has one verdict, readable top to bottom.
- Rules apply **when a window first appears** (and to the windows found when Gio starts). Workspace assignment is not re-applied after a config reload.
- `open-on-workspace` sends the window to that named workspace, on whichever display holds it. Following (`follow`) only happens for windows that appear while Gio runs (a new window, or the windows of an app you just launched), never for the windows Gio finds at startup or on a rescan. A minimized window never takes you anywhere. `floating` and the other rule keys still apply.
- On reload, float rules are re-evaluated: a newly matching `floating` rule floats the window (reason `rule`), and a window whose rule no longer matches goes back to tiled. Windows floated by admission (dialog, panel, not resizable) or by the user are never promoted or relabeled.
- A `tiled` rule does not override admission: a fixed-size window still floats.
- An invalid rule (neither `app` nor `bundle-id`, bad `mode`, workspace outside 1 to 9, bad `follow`) is a config error and rejects the whole file.

## Desktop app

`Gio.app` is one process: menu bar item, a main window and the launcher. It shows a Dock icon only while the main window is visible. Closing the window hides it; Gio keeps tiling from the menu bar.

### Main window sections

| Section | What it shows or does |
| --- | --- |
| **Overview** | Named workspaces appear with their icon, color and `1 · Code` title in the workspace pills, the live strip header and the window list headers (dynamic ones keep `Workspace N`). Session status, Accessibility permission (with a **Request Access** button), Screen Recording permission (with a **Request access** button and a relaunch hint), config summary and any config messages, display and workspace lines, and every managed window with its application, title, workspace and state (tiled, floating with reason, minimized, hidden). Refreshes every 3 s while the window is visible (nothing runs when it is closed to the menu bar). |
| **Shortcuts** | Searchable reference of every action grouped by category (Focus, Move, Columns, Windows, Workspaces, App) with its current bindings, description and source (`default` or `config`). View-only: shortcuts are changed in `config.toml`. |
| **Workspaces** | Named workspaces as cards in config order (the order of `Alt+1`, `Alt+2`, ...). Create one with **New Workspace** (`Cmd+N`), or from the empty state with a template (Code, Browsers, Chat, Design: icon and color only, apps are yours to add). Per card: click the icon to pick an SF Symbol (curated grid with search; **Use Number** shows the position instead), pick a color (preset swatches or the color well), rename inline (a name must be non-empty and unique, case-insensitive), choose a **Display** (Main or Display N; shown with more than one display), and reorder by dragging the handle or with the up/down arrows. **Apps** lists the apps whose new windows open there: **Add App** opens a picker with running and installed apps (`/Applications`, `/System/Applications`, `~/Applications`, one folder deep; icons, search, multi-select). An app belongs to one workspace: picking one that another workspace holds moves it, and the picker says so before you confirm. Each app chip's menu sets **Follow** (When Active, Always, Never) or removes it. Deleting a workspace asks first; its windows move to a regular workspace. Edits stay unsaved until **Apply**, which writes `[[workspace]]` blocks and `[[window-rules]]` with `bundle-id`, `app`, `open-on-workspace` and `follow` (an app that already has a rule gets those keys on that rule, so an earlier rule never shadows a new one; removing an assignment keeps the rule when it still sets a mode) and reloads live. Renames update the rules that point at the workspace. |
| **Layout** | Gaps, padding, default width (fraction or points), preset widths (comma separated), the center-focused-column mode, the two Focus toggles (focus follows mouse, mouse follows focus), the **Focus indicator** (Dim / Ring / None; Dim shows a strength slider) and, with Ring selected, the ring settings (enable, width, hide on maximized/fullscreen, and color: a native color picker, preset swatches, a hex field kept in sync and a live preview; the ring is always opaque, so there is no opacity control; Apply writes `active-color = "#rrggbb"` and the ring updates immediately). **Apply** patches `config.toml` in place and reloads live; **Revert** restores the form. Invalid values are explained inline and Apply stays disabled. |
| **Animations** | Enable toggle, curve, spring or duration controls and the Resize mode (Never, Adaptive, Always) and the Renderer (Snapshot, Accessibility). Apply and Revert as above. |
| **Rules** | List of window rules with Add, Edit and Delete. Same validation as the file. A rule with `open-on-workspace` shows the workspace name. |
| **Logs** | Live tail (last 500 rows, current file only) of `~/.config/gio/gio.log` with a minimum-level picker, text search, auto-scroll, **Copy visible** and **Clear view** (hides what is already in the file; it does not delete it). |
| **Diagnostics** | Facts: version and build, session, Accessibility, Screen Recording, config path and validity, IPC socket, display count, log file path. Buttons: **Reload Config**, **Restore All Windows** (brings parked windows on screen without quitting; tiling stays on, so the next layout change parks them again), **Test snapshot capture** (debug: captures the visible windows once and shows the summary, latency included; needs Screen Recording), **Open Config File**, **Quit Gio**. |

Settings edits are text-level: unrelated lines, comments and ordering survive, the result must re-parse before it is written, and the write is atomic (temp file plus rename). If the existing file has parse errors, edits are refused until it is fixed. Known gap: editing a rule from the app drops comments inside that rule block.

### Menu bar item

Title `Gio` (or `workspace · windows`), pushed by the session when it changes; no polling. Menu: **Open Gio**, the workspace stack of each display (**Workspace N · windows**, check mark on the active one, only the focused display's rows switch; a named workspace shows its icon and name with its `Alt` number, for example **Code ⌥1 · 2 windows**, and the header reads `Code (1 of 4)`; the status item badge keeps the index), window and column counts, **Reload Config**, **Preferences...** (opens the main window), **Launcher...**, **Quit Gio**. With no session it shows `no session` and disables session actions. **Quit Gio** runs the normal shutdown, which restores parked windows.

## Launcher

`Alt+Space` opens a small panel. Type to filter installed apps (top-level `.app` bundles in `/Applications`, `~/Applications`, `/System/Applications`) and Gio's managed windows, then press Enter. Named workspaces of the focused display match by name: typing `code` offers **Go to workspace Code** (kind **Workspace**), which switches there through the same path as `gio workspace N` (so focus follows like the hotkey). Windows are listed as `App — Title` with a window icon and their workspace; minimized windows are left out.

| Input | Effect |
| --- | --- |
| text | Fuzzy match over app names and windows (prefix, then substring, then ordered subsequence; a window matches by app name, by title, or both, and a title-only match ranks one step below an app-name match). On an equal rank workspaces come first, then windows, then apps. Enter runs the best match, or click a row. |
| a window | Switches to its workspace if needed, scrolls it into view and gives it keyboard focus, like a focus hotkey (including `center-focused-column` and `mouse-follows-focus`). |
| `> <verb>` | Run a Gio command over IPC, for example `> workspace 2` or `> reload`. |
| `! <command>` | Run a shell command with `/bin/zsh -c`. |

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
| `gio move left\|right\|up\|down` | Move the focused column (left/right) or window (up/down) like `Alt+Shift+H/L/K/J`. (The built-in usage text prints `up/down`; the parser wants `up` or `down`.) |
| `gio workspace 1...9` | Focus the workspace at this position of the focused display's stack (past the end: the empty one at the bottom). |
| `gio layout info` | Current workspace columns, viewport offset, focused column and column widths. |
| `gio status` | JSON snapshot: `workspace` (index of the current workspace in its stack), `stacks` (per display: `display`, `focused`, `active`, and `workspaces` with `index`, `windows`, `columns`, `active`, plus `name`, `icon` and `color` for named workspaces), `focusedWindow`, `columns`, `windows`, `modes`, `floatingWindows`, `minimizedWindows`. Used by scripts and the menu bar. |
| `gio setup` | Checks permission, writes the config template if none exists, reports bindings and themes. |
| `gio doctor` | Health report: Accessibility, config, version, IPC, displays, recent errors. |
| `gio update` | Reports that updates are not published yet. |
| `gio uninstall` | Removes the socket and lock files only when no session holds the lock; keeps your config and themes. |
| `gio logs [--level trace\|debug\|info\|warn\|error]` | Print the log file, optionally at or above a level. |
| `gio help` | Usage. |

Not every keyboard action has a CLI verb (for example column widths, maximize, fullscreen, consume/expel and center have none).

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
