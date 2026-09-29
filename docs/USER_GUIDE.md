# User guide

How to use Gio day to day: shortcuts, configuration, window rules, the desktop app and the command line. Everything here is derived from `defaultHotkeyBindings`, `ShortcutCatalog`, the config parser and the command grammar in the source.

Contents: [Concepts](#concepts) · [Shortcuts](#default-shortcuts) · [Config](#configuration-reference) · [Rules](#window-rules) · [Desktop app](#desktop-app) · [Launcher](#launcher) · [CLI](#command-line-gio) · [gio-poc](#gio-poc)

## Concepts

- **Strip and viewport.** Each workspace is a horizontal strip of **columns**. A column stacks one or more windows vertically. The display is a viewport onto the strip and scrolls to keep the focused column visible.
- **Workspaces.** Nine (`1` to `9`). Windows of workspaces that no display shows are hidden off the bottom corner of the display.
- **Modes.** A window is `tiled` (in the strip), `floating` (managed but outside the strip, keeps its own frame) or `fullscreen` (Gio's layout mode filling the display under the menu bar, not a native macOS fullscreen Space).
- **Alt** means the **Option** key.

## Default shortcuts

Shortcuts are global while Gio runs and Accessibility permission is granted. A bound combo is swallowed (the app never sees it); everything else passes through untouched. All shortcuts below except the launcher can be rebound in `[keybindings]`.

| Shortcut | Action (config name) | What it does |
| --- | --- | --- |
| `Alt+H` | `focus-left` | Focus the column to the left. |
| `Alt+L` | `focus-right` | Focus the column to the right. |
| `Alt+K` | `focus-up` | Focus the window above in the current column. |
| `Alt+J` | `focus-down` | Focus the window below in the current column. |
| `Alt+Shift+H` | `move-left` | Move the focused window's column one place to the left. |
| `Alt+Shift+L` | `move-right` | Move the focused window's column one place to the right. |
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
| `Alt+1` ... `Alt+9` | `workspace N` | Go to workspace N. |
| `Alt+Shift+1` ... `Alt+Shift+9` | `move-to-workspace N` | Send the focused window to workspace N. |
| `Alt+Space` | (launcher, fixed) | Summon the launcher panel. Handled by the app before the action table; not configurable. |

That is 35 default action bindings plus the launcher. The **Shortcuts** section of the app lists the same table live, with the source of each binding (`default` or `config`).

Notes:

- Vertical direction naming: `move-left`/`move-right` move a whole column, `move-up`/`move-down` reorder inside a column. Moving past the strip edge creates a new column.
- Shrink/grow always end as a proportion of the display, so the column adapts across displays.
- Fullscreen parks every tiled window where its column already is, so leaving fullscreen finds the strip unchanged.
- Focus, move, workspace, consume/expel and fullscreen actions also move macOS keyboard focus to the target window (after it lands, at the end of the animation). Sizing, centering and floating actions leave focus alone, and so do clicks and window events.

## Configuration reference

**File:** `~/.config/gio/config.toml`. Created from a commented template by `GioCLI setup`, **Diagnostics > Open Config File**, or the first edit in a Settings section. Changes apply with `gio reload`, **Diagnostics > Reload Config**, or automatically after **Apply** in Settings.

### Format rules

Gio parses a strict **subset of TOML**:

- Tables `[layout]`, `[behavior]`, `[animations]`, `[keybindings]` and array tables `[[window-rules]]`.
- `key = value` with double-quoted strings, integers, decimals, `true`/`false`, and flat lists of numbers like `[0.33, 0.5, 800]` (a trailing comma is tolerated; nested lists are not).
- `#` comments outside quotes. Keys may be quoted (`"Alt+H" = ...`).
- No escapes in strings, no multi-line values, no inline tables.

Validation outcomes:

| Problem | Result |
| --- | --- |
| Syntax error, key outside any table, wrong value type, value out of range, unknown action name, unparsable hotkey, rule without a valid `app` | **Error.** The whole file is rejected, **defaults are used**, and every message (with its line number) is shown in the app (**Overview**, **Diagnostics**) and returned by `gio reload`. |
| Unknown table or unknown key inside a known table | **Warning.** Ignored, everything else applies (forward compatibility). |
| `animations.duration-ms` outside 0 to 1000 | **Warning.** Clamped into range. |
| Missing file | Silent defaults (first run). |

An invalid config never stops the window manager.

### `[layout]`

| Key | Type | Default | Validation and meaning |
| --- | --- | --- | --- |
| `gaps` | number (points) | `8` | Non-negative. Space between columns and between windows in a column. |
| `padding` | number (points) | `8` | Non-negative. Outer margin around the strip inside the usable display area. |
| `default-column-width` | number | `0.5` | Positive. `<= 1` is a **proportion** of the strip (Niri semantics, `p * (viewport - 2*padding + gap) - gap`, so two `0.5` columns fill the screen exactly). `> 1` is an absolute width in points. Columns are never narrower than 200 pt. |
| `preset-column-widths` | list of numbers | `[0.33333, 0.5, 0.66667]` | Non-empty list of positive numbers, same `<= 1` proportion vs points rule. `Alt+R` cycles through them. |
| `center-focused-column` | bool | `true` | Parsed and stored, **not consumed** by the running session yet. |

### `[behavior]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `focus-follows-mouse` | bool | `false` | Parsed and stored, **not consumed** yet. |
| `mouse-follows-focus` | bool | `true` | Parsed and stored, **not consumed** yet. |

### `[animations]`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Off makes every reflow instant. |
| `duration-ms` | number | `200` | Length of one animation. Rounded and clamped to `0...1000` with a warning. `0` is instant. |

### Custom key bindings

The `[keybindings]` table maps a combo to an action name: `"Alt+H" = "focus-left"`.

- **Combo syntax:** one or more modifiers plus one key, joined by `+`. Modifiers (case-insensitive): `ctrl`/`control`, `alt`/`option`, `shift`, `cmd`/`command`. At least one modifier is required. Keys: a single letter or digit (letters are upper-cased), `Space`, and punctuation `Minus` (or `-`), `Equal` (or `=`), `BracketLeft` (or `[`), `BracketRight` (or `]`).
- **Action names:** `focus-left`, `focus-right`, `focus-up`, `focus-down`, `move-left`, `move-right`, `move-up`, `move-down`, `workspace N`, `move-to-workspace N` (write them as `"workspace 3"`; use N from 1 to 9, other values do nothing), `toggle-floating` (alias `toggle-window-floating`), `fullscreen` (alias `fullscreen-window`), `switch-preset-column-width`, `set-column-width-minus`, `set-column-width-plus`, `maximize-column`, `center-column`, `consume-or-expel-window-left`, `consume-or-expel-window-right`.
- **Bindings are additive.** Config entries are layered over the defaults: a config entry binds a combo (replacing the default action of that exact combo). Default bindings stay active unless you reuse their combo for another action; there is no unbind syntax.
- **Supported keys are limited by the key tap.** The hotkey tap knows only these keys: letters `H J K L R F C`, digits `1` to `9`, `Space`, `Minus`, `Equal`, `BracketLeft`, `BracketRight`. A binding on any other key (for example `Alt+Q`) parses without error but never fires. Extending the table is a code change (see [CONTRIBUTING](CONTRIBUTING.md#add-a-new-hotkey-action)).
- `Alt+Space` (launcher) cannot be rebound or removed.

### `[[window-rules]]`

See [Window rules](#window-rules).

### Example

```toml
[layout]
gaps = 8
padding = 8
default-column-width = 0.5
preset-column-widths = [0.33333, 0.5, 0.66667]

[animations]
enabled = true
duration-ms = 200

[keybindings]
"Alt+Shift+R" = "switch-preset-column-width"

[[window-rules]]
app = "Calculator"
mode = "floating"

[[window-rules]]
app = "Notes"
workspace = 2
```

## Window rules

A rule is a `[[window-rules]]` block:

| Key | Required | Values | Meaning |
| --- | --- | --- | --- |
| `app` | yes | non-empty string | **Exact** application name as macOS reports it (`localizedName`). No globs, no prefixes, no bundle IDs. |
| `mode` | no | `"tiled"`, `"floating"`, `"fullscreen"` | Force the window's mode. |
| `workspace` | no | integer `1` to `9` | Put the window on this workspace when it appears. |

Behavior:

- **First matching rule wins, entirely.** Later rules never merge, so one app has one verdict, readable top to bottom.
- Rules apply **when a window first appears**. Workspace assignment is not re-applied after a config reload.
- On reload, float rules are re-evaluated: a newly matching `floating` rule floats the window (reason `rule`), and a window whose rule no longer matches goes back to tiled. Windows floated by admission (dialog, panel, not resizable) or by the user are never promoted or relabeled.
- A `tiled` rule does not override admission: a fixed-size window still floats.
- An invalid rule (missing `app`, bad `mode`, workspace outside 1 to 9) is a config error and rejects the whole file.

## Desktop app

`Gio.app` is one process: menu bar item, a main window and the launcher. It shows a Dock icon only while the main window is visible. Closing the window hides it; Gio keeps tiling from the menu bar.

### Main window sections

| Section | What it shows or does |
| --- | --- |
| **Overview** | Session status, Accessibility permission (with a **Request Access** button), config summary and any config messages, display and workspace lines, and every managed window with its application, title, workspace and state (tiled, floating with reason, minimized, hidden). Refreshes every 2 s. |
| **Shortcuts** | Searchable reference of every action grouped by category (Focus, Move, Columns, Windows, Workspaces, App) with its current bindings, description and source (`default` or `config`). View-only: shortcuts are changed in `config.toml`. |
| **Layout** | Gaps, padding, default width (fraction or points), preset widths (comma separated), center-focused-column, and the two Focus toggles (focus follows mouse, mouse follows focus). **Apply** patches `config.toml` in place and reloads live; **Revert** restores the form. Invalid values are explained inline and Apply stays disabled. |
| **Animations** | Enable toggle and duration slider (0 to 1000 ms). Apply and Revert as above. |
| **Rules** | List of window rules with Add, Edit and Delete. Same validation as the file. |
| **Logs** | Live tail of `~/.config/gio/gio.log` with a minimum-level picker, text search, auto-scroll and **Clear view** (hides what is already in the file; it does not delete it). |
| **Diagnostics** | Facts: version and build, session, Accessibility, config path and validity, IPC socket, display count, log file path. Buttons: **Reload Config**, **Restore All Windows** (brings parked windows on screen without quitting; tiling stays on, so the next layout change parks them again), **Open Config File**, **Quit Gio**. |

Settings edits are text-level: unrelated lines, comments and ordering survive, the result must re-parse before it is written, and the write is atomic (temp file plus rename). If the existing file has parse errors, edits are refused until it is fixed. Known gap: editing a rule from the app drops comments inside that rule block.

### Menu bar item

Title `Gio` (updated from the status query every 3 s). Menu: **Open Gio**, **Workspace 1** to **Workspace 9** (check mark on the current one), window and column counts, **Reload Config**, **Preferences...** (opens the main window), **Launcher...**, **Quit Gio**. With no session it shows `no session` and disables session actions. **Quit Gio** runs the normal shutdown, which restores parked windows.

## Launcher

`Alt+Space` opens a small panel. Type to filter installed apps (top-level `.app` bundles in `/Applications`, `~/Applications`, `/System/Applications`), then press Enter.

| Input | Effect |
| --- | --- |
| text | Fuzzy match over app names (prefix, then substring, then ordered subsequence). Enter opens the best match. |
| `> <verb>` | Run a Gio command over IPC, for example `> workspace 2` or `> reload`. |
| `! <command>` | Run a shell command with `/bin/zsh -c`. |

The shortcut catalog describes the launcher as searching "apps and windows"; the implementation searches apps only.

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
| `gio restart` | Parses, but only answers that it needs the running session; it does not restart anything. |
| `gio list-windows` | One line per managed window: pid, app, title, frame, mode, reason, minimized. |
| `gio list-workspaces` | The nine workspaces with column and window counts; the current one is marked `*`. |
| `gio focus left\|right\|up\|down` | Move focus like `Alt+H/L/K/J`. |
| `gio move left\|right\|up\|down` | Move the focused window like `Alt+Shift+H/L/K/J`. (The built-in usage text prints `up/down`; the parser wants `up` or `down`.) |
| `gio workspace 1...9` | Switch workspace. |
| `gio layout info` | Current workspace columns, viewport offset, focused column and column widths. |
| `gio status` | JSON snapshot: `workspace`, `focusedWindow`, `columns`, `windows`, `modes`, `floatingWindows`, `minimizedWindows`. Used by scripts and the menu bar. |
| `gio setup` | Checks permission, writes the config template if none exists, reports bindings and themes. |
| `gio doctor` | Health report: Accessibility, config, version, IPC, displays, recent errors. |
| `gio update` | Reports that updates are not published yet. |
| `gio uninstall` | Removes the socket and lock files only when no session holds the lock; keeps your config and themes. |
| `gio logs [--level trace\|debug\|info\|warn\|error]` | Print the log file, optionally at or above a level. |
| `gio help` | Usage. |

Not every keyboard action has a CLI verb (for example column widths, maximize, fullscreen, consume/expel and center have none).

## `gio-poc`

`gio-poc` is the Accessibility proof-of-concept tool (`swift run gio-poc <verb>`). It talks to Accessibility directly, needs Accessibility permission for the terminal or tool that runs it, and does **not** go through the running app. Window indices are positional within one fresh enumeration per call.

| Verb | Effect |
| --- | --- |
| `list-windows` | Print discovered windows and the skipped count. |
| `focus <index>` | Focus that window. |
| `move <index> <x> <y>` | Move a window. |
| `resize <index> <width> <height>` | Resize a window (positive sizes only). |
| `tile` | One-shot placement of one column per window on the main display. **Do not run against a live desktop while Gio is running**: it competes with the session. |
| `restore` | Bring parked or off-screen windows fully back on screen. Use after Gio was killed. |
| `events` | Print window and app events until interrupted. |
| `help` | Usage. |

Shared Xcode schemes in `Gio.xcworkspace`: `gio-poc-list`, `gio-poc-tile`, `gio-poc-restore` (each runs the matching verb) and `gio-doctor` (runs `doctor`).
