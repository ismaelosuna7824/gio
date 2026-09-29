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
    center-focused-column = true
    # Widths Alt+R cycles through: fractions of the screen (<= 1) or points.
    preset-column-widths = [0.33333, 0.5, 0.66667]

    [behavior]
    focus-follows-mouse = false
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
    # "maximize-column" (Alt+F, toggles back to the previous width).

    [[window-rules]]
    app = "Calculator"
    mode = "floating"
    """
}
