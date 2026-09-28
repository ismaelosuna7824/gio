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

    [behavior]
    focus-follows-mouse = false
    mouse-follows-focus = true

    [keybindings]
    "Alt+H" = "focus-left"
    "Alt+L" = "focus-right"
    "Alt+J" = "focus-down"
    "Alt+K" = "focus-up"

    [[window-rules]]
    app = "Calculator"
    mode = "floating"
    """
}
