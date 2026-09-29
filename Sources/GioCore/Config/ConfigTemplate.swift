import Foundation

/// Starter config written only when none exists. Mirrors the parser subset
/// and the plan example — self-check in tests parses it back with zero
/// warnings. Unknown keys warn, invalid values fall back; nothing here can
/// break the window manager.
public func defaultConfigTemplate() -> String {
    """
    # Gio config — unknown keys warn, invalid values fall back to defaults.
    [layout]
    gaps = 8
    padding = 8
    default-column-width = 0.5
    # Niri semantics: "never" scrolls minimally, "always" centers the focused
    # column on every keyboard focus change, "on-overflow" centers only when it
    # does not fit next to the previously focused column.
    center-focused-column = "never"
    # Widths Alt+R cycles through: fractions of the screen (<= 1) or points.
    preset-column-widths = [0.33333, 0.5, 0.66667]

    [behavior]
    # Focus the window the pointer rests on (~100 ms); never scrolls.
    focus-follows-mouse = false
    # Warp the cursor to the focused window after a keyboard focus change.
    mouse-follows-focus = true

    [animations]
    enabled = true
    duration-ms = 200

    [keybindings]
    "Alt+H" = "focus-left"
    "Alt+L" = "focus-right"
    "Alt+J" = "focus-down"
    "Alt+K" = "focus-up"
    # Also available: "switch-preset-column-width" (Alt+R),
    # "set-column-width-minus" (Alt+Minus), "set-column-width-plus" (Alt+Equal),
    # "maximize-column" (Alt+F, toggles back to the previous width),
    # "center-column" (Alt+C, scrolls the focused column to the middle),
    # "consume-or-expel-window-left" (Alt+[) and "...-right" (Alt+]): pull the
    # window into the neighbouring column, or push it out of a stacked one.
    # "fullscreen" (Alt+Shift+F; alias "fullscreen-window"; fills the display
    # under the menu bar, focusing another window restores the layout),
    # "toggle-floating" (Alt+Shift+Space; alias "toggle-window-floating").

    [[window-rules]]
    app = "Calculator"
    mode = "floating"
    """
}
