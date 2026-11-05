# SketchyBar

[SketchyBar](https://github.com/FelixKratz/SketchyBar) can show Gio's workspaces instead of the macOS menu bar. Four Gio pieces make it work, the same way bars work with AeroSpace or yabai:

| Piece | What it does |
| --- | --- |
| `[hooks]` | Gio runs a shell command when the workspace or window state changes: here `sketchybar --trigger ...`, so SketchyBar redraws ([reference](USER_GUIDE.md#hooks)). |
| `gio list-workspaces --json` | The plugin script reads every workspace: display, position, name, focused, shown, window count and app names ([reference](USER_GUIDE.md#command-line-gio)). |
| `gio workspace N` | A click on a workspace item switches to it. |
| `[layout] reserved-top` | Keeps the bar's height free at the top of every display, so tiled windows never sit under the bar ([reference](USER_GUIDE.md#layout)). |

> Status: tried live on a notched MacBook Pro (macOS 26) with Gio's dev build: hooks fire on every switch (`hook ran ... status=0`, 12-30 ms), the bar follows a workspace change in about 150 ms, a click on an item switches workspace, and the `gio` link answers. The macOS 26 notes below come from that run.

## 1. Install the `gio` command

In Gio, open **Diagnostics > Command Line** and click **Install Command Line Tool**. It links `~/.local/bin/gio` to `Gio.app` (the app binary answers as the `gio` client). Check it:

```sh
~/.local/bin/gio list-workspaces --json
```

The scripts below call `$HOME/.local/bin/gio` by its full path, so they work even when `~/.local/bin` is not on SketchyBar's `PATH` (and never pick up Homebrew `glib`'s unrelated `gio`).

You also need `jq` (`brew install jq`) and SketchyBar (`brew install FelixKratz/formulae/sketchybar`).

## 2. Gio config

Add to `~/.config/gio/config.toml` (or set **Space for a custom bar (top)** in Settings > Layout), then `gio reload`:

```toml
[layout]
# The bar's height in points (the bar below sets height=32).
reserved-top = 32

[hooks]
on-workspace-change = "sketchybar --trigger gio_workspace_change"
on-windows-change = "sketchybar --trigger gio_windows_change"
```

Gio runs each hook with `/bin/sh -c`, off its window-manager queue, with its output discarded, stopped after 5 s and at most one run at a time (changes during a run fold into one more run). `on-workspace-change` fires when you switch workspace or display (and once when Gio starts); `on-windows-change` fires about 100 ms after windows open, close or move. The shell sees `GIO_FOCUSED_WORKSPACE`, `GIO_FOCUSED_WORKSPACE_NAME`, `GIO_PREV_WORKSPACE` and `GIO_DISPLAY`; Gio adds `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` to its `PATH`, so `sketchybar` resolves even though apps opened from Finder get a short `PATH`. To hand the values to SketchyBar's scripts, pass them to the trigger (use single quotes inside the TOML string, it has no escapes):

```toml
on-workspace-change = "sketchybar --trigger gio_workspace_change FOCUSED_WORKSPACE=$GIO_FOCUSED_WORKSPACE"
```

Fullscreen windows (`Alt+Shift+F`) still cover the reserved band; every other layout (scrolling, dwindle, maximized and filled columns) stays below it.

## 3. Hide the macOS menu bar

SketchyBar draws at the top of the screen, where the menu bar is. Let macOS hide it: **System Settings > Control Center > Automatically hide and show the menu bar: Always** (on macOS 13 the setting is under **Desktop & Dock**). The menu bar then slides in only when the pointer touches the top edge, and Gio's usable area starts at the top of the display, less `reserved-top`.

To keep the menu bar instead, put the bar under it (`sketchybar --bar y_offset=<menu bar height>`) and keep `reserved-top` equal to the bar's height: the menu bar is already outside Gio's usable area.

**Notched displays.** With the menu bar hidden, macOS still keeps the notch row out of the usable area, so a 32 pt bar in that row (`y_offset` about 2) needs `reserved-top = 0`: Gio already tiles below the row.

**macOS 26: hidden menu bar items still take the pointer.** The hidden menu bar stays as one invisible window over the top row, above SketchyBar. Where a hidden status item sits (third-party apps on the right, such as Tinybar or Droppy), the first click goes to that item and its tooltip shows up over the bar. Turn those apps off in **System Settings > Menu Bar > Allow in the Menu Bar**, keep clickable bar items away from them, or put the bar under the row. SketchyBar's aliases of status items do not work there either: macOS 26 draws every status item inside that one window, so an alias captures the wrong window.

## 4. `~/.config/sketchybar/sketchybarrc`

Add this to your `sketchybarrc` (a bash script; a fresh one starts with `#!/bin/bash`). It adds the two events, nine workspace items (Gio addresses positions 1 to 9), and a hidden `gio` item whose script redraws them all:

```bash
GIO="$HOME/.local/bin/gio"

sketchybar --bar position=top height=32 color=0xcc1e1e2e

sketchybar --add event gio_workspace_change \
           --add event gio_windows_change

for i in 1 2 3 4 5 6 7 8 9; do
  sketchybar --add item "space.$i" left \
             --set "space.$i" drawing=off \
                   icon="$i" \
                   icon.padding_left=8 \
                   icon.padding_right=4 \
                   label.padding_right=8 \
                   label.drawing=off \
                   background.color=0x55ffffff \
                   background.corner_radius=6 \
                   background.height=24 \
                   background.drawing=off \
                   click_script="$GIO workspace $i"
done

sketchybar --add item gio left \
           --set gio drawing=off updates=on script="$CONFIG_DIR/plugins/gio.sh" \
           --subscribe gio gio_workspace_change gio_windows_change system_woke

sketchybar --update
```

`updates=on` lets the hidden `gio` item run its script although it is never drawn. `sketchybar --update` runs it once at load; Gio's hooks also fire once when Gio starts.

## 5. `~/.config/sketchybar/plugins/gio.sh`

```bash
#!/bin/bash
# Gio workspaces for SketchyBar: redraws space.1 ... space.9 from
# `gio list-workspaces --json`, showing the focused display's stack.
GIO="$HOME/.local/bin/gio"
JSON="$("$GIO" list-workspaces --json 2>/dev/null)" || exit 0

# One line per workspace of the focused display: position, label,
# focused, window count (fields separated by the unit separator 0x1f).
ROWS="$(jq -r '
  (map(select(.focused)) | first | .display) as $display
  | .[] | select(.display == $display)
  | [(.index | tostring), (.name // (.index | tostring)), (.focused | tostring), (.windows | tostring)]
  | join("\u001f")' <<<"$JSON")"

args=()
shown=" "
while IFS=$'\x1f' read -r index label focused windows; do
  [ -n "$index" ] && [ "$index" -le 9 ] || continue
  shown="$shown$index "
  highlight=off
  [ "$focused" = true ] && highlight=on
  count=on
  [ "$windows" = 0 ] && count=off
  args+=(--set "space.$index" drawing=on icon="$label" label="$windows" \
         label.drawing="$count" background.drawing="$highlight")
done <<<"$ROWS"

# Positions the stack does not have right now.
for i in 1 2 3 4 5 6 7 8 9; do
  case "$shown" in
    *" $i "*) ;;
    *) args+=(--set "space.$i" drawing=off) ;;
  esac
done

sketchybar "${args[@]}"
```

Make it executable and reload SketchyBar:

```sh
chmod +x ~/.config/sketchybar/plugins/gio.sh
sketchybar --reload
```

Each item shows the workspace's name (or its position for a dynamic workspace) and its window count; the focused workspace gets the highlight. Gio always keeps one empty workspace at the bottom of each stack (Niri style), so the last item is usually empty. Clicking an item runs `gio workspace N`, which acts on the focused display, the same display the items show.

## What the JSON holds

`gio list-workspaces --json` prints one array, one object per workspace, keys sorted, main display first and each stack top to bottom:

```json
[{"apps":["Safari","Mail"],"color":"#ff8800","display":1,"focused":true,"icon":"globe","index":1,"name":"Web","visible":true,"windows":3},
 {"apps":[],"color":null,"display":1,"focused":false,"icon":null,"index":2,"name":null,"visible":false,"windows":0}]
```

- `display`: the display number `[[workspace]] display` uses (1 is the main display, the others by position).
- `index`: the position in that display's stack (what `gio workspace N` takes).
- `name`, `icon`, `color`: from `[[workspace]]`, `null` for a dynamic workspace. `icon` is an SF Symbol name; SketchyBar needs a font that has it (for example SF Pro) or your own mapping.
- `focused`: the focused display's shown workspace. `visible`: shown on its display.
- `windows`: every window the workspace holds (floating and minimized ones too). `apps`: their app names, unique, in column order. Window titles are never included.

To show the apps, read `.apps | join(" ")` in the `jq` filter and set it as the item's label, or map app names to icon glyphs (as `sketchybar-app-font` does).

## Troubleshooting

- **Nothing updates.** Set `[logging] level = "debug"`, `gio reload`, switch workspace and look for `hook ran name=on-workspace-change ms=... status=0` in the Logs section. `status=127` means the shell did not find `sketchybar`; use its full path (`/opt/homebrew/bin/sketchybar`). `status=timeout` means the command ran longer than 5 s.
- **Items stay hidden.** Run `~/.config/sketchybar/plugins/gio.sh` in Terminal; `jq` errors show there. Check that `gio list-workspaces --json` answers (Gio must be running).
- **Windows sit under the bar.** `reserved-top` must be at least the bar's height (plus its `y_offset` when the menu bar is hidden and the bar is offset).
- **Fonts show as text (`:safari:`) or boxes.** A font installed by Homebrew can stay quarantined and inactive: `xattr -d com.apple.quarantine ~/Library/Fonts/<font>.ttf`, then `brew services restart sketchybar`. SF Symbols need Apple's SF Pro (`brew install --cask font-sf-pro`, asks for your password); `font-symbols-only-nerd-font` gives icons without it.
