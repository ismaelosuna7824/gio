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
    # Gap (points, 0-64) kept around a fullscreen window (Alt+Shift+F). Unset
    # follows `gaps`; 0 is edge to edge. The focus ring shows in fullscreen
    # when this gap is at least the ring width.
    # fullscreen-gap = 8
    default-column-width = 0.5
    # Niri semantics: "never" scrolls minimally, "always" centers the focused
    # column on every keyboard focus change, "on-overflow" centers only when it
    # does not fit next to the previously focused column.
    center-focused-column = "never"
    # Where a new window's column opens in the strip: "end", "start",
    # "right-of-focused" or "left-of-focused" (the focused column of the
    # workspace it opens on). Windows found at startup keep their order.
    new-window-position = "end"
    # Widths Alt+R cycles through: fractions of the screen (<= 1) or points.
    preset-column-widths = [0.33333, 0.5, 0.66667]
    # Heights Alt+Shift+R cycles the focused window of a stacked column
    # through: fractions of the usable screen height (<= 1) or points.
    preset-window-heights = [0.33333, 0.5, 0.66667]
    # A workspace with a single window shows it at full width (like Alt+F);
    # a second window brings the column widths back. false keeps the width.
    maximize-single-window = true
    # A workspace with a single column shows it in the middle of the screen
    # instead of at the left edge (niri always-center-single-column).
    always-center-single-column = false
    # Layout of new workspaces: "scrolling" (the strip of columns) or "dwindle"
    # (a split tree that keeps every window on screen). Alt+Shift+T switches
    # the current workspace; [[workspace]] layout = "..." sets one workspace.
    default-layout = "scrolling"

    [dwindle]
    # Dwindle workspaces. A new window splits the focused one; this is the
    # share the focused window keeps, times two (0.1-1.9; 1.0 is half and half).
    default-split-ratio = 1.0
    # A split puts its halves side by side when its area is at least this many
    # times wider than tall, else stacks them (0.1-10; above 1 favours stacking).
    split-width-multiplier = 1.0

    [behavior]
    # Focus the window the pointer rests on (~100 ms); never scrolls.
    focus-follows-mouse = false
    # Warp the cursor to the focused window after a keyboard focus change.
    mouse-follows-focus = true
    # With two or more displays: the window move (Alt+Shift+H / J / K / L) from
    # the workspace's edge sends the window to the display on that side,
    # stacked into the column nearest that edge; the column move
    # (Alt+Shift+< / >) at the first / last column sends the column there.
    move-crosses-monitor-at-edge = false

    [animations]
    enabled = true
    # "spring" (Niri-style, default) or "ease-out". A spring keeps the speed
    # of a move it interrupts, so rapid key presses flow; duration-ms only
    # sets the length of "ease-out" (0 still means instant for both).
    curve = "spring"
    duration-ms = 200
    # Spring tuning: damping ratio 0.2-3 (1 = no overshoot, lower bounces),
    # stiffness 100-3000 (higher is faster).
    spring-damping-ratio = 1.0
    spring-stiffness = 800
    # Windows that grow (maximize, widen): "never" (default) grows them once
    # at the end, "adaptive" grows them during the motion when the app keeps
    # up and nothing is in the way, "always" ignores how well the app keeps
    # up (still never overlaps a neighbour).
    resize = "never"
    # The focused window that grows (maximize, fullscreen, wider preset):
    # "start" (default) gives it its final size in the first frame, so it is
    # not cut while the neighbours slide away (it may overlap them during the
    # flight); "end" waits for the final pass like every other window.
    focused-grow = "start"
    # Maximize (Alt+F) on a single-window column presses the app's own zoom
    # (the double-click on the title bar) instead of writing a new size: the
    # app animates it in-process, so it does not wait to repaint. Gio keeps
    # the frame the zoom lands on when it is close to the layout target and
    # corrects or falls back to a normal write otherwise. Stacked columns and
    # apps without a zoom button use the normal write. Set false to disable.
    native-zoom = true
    # How motion is drawn: "snapshot" (default) slides images of the windows at
    # the display's refresh rate, the same speed with every app, and moves the
    # real windows once; it needs the Screen Recording permission (Gio uses "ax"
    # while it is missing). "ax" moves the real windows every frame, so content
    # stays live, but slow apps move at their own pace.
    renderer = "snapshot"

    # Per-animation tuning, with Niri's names. Each table inherits every key
    # of [animations] and may set its own: enabled, curve, duration-ms,
    # spring-damping-ratio, spring-stiffness. [animations] enabled = false
    # still turns everything off. A pass uses the animation of the action
    # that triggered it; new windows always use window-open and windows
    # crossing the bottom edge always use workspace-switch.
    [animations.horizontal-view-movement]
    # Scrolling the view: focus changes, centering.

    [animations.window-movement]
    # Moving windows and columns, consume/expel, and passive relayouts.

    [animations.workspace-switch]
    # Windows leaving or entering through the bottom edge.

    [animations.window-open]
    # A new window rises into its column from this many points below (0-200;
    # 0 places it without a flight), while the others make room.
    # offset = 24

    [animations.window-close]
    # The neighbours close the gap. ghost = true also fades out an image of
    # the closed window (needs Screen Recording; off by default).
    # ghost = false

    [animations.window-resize]
    # Maximize, fullscreen and width changes (native zoom neighbours too).
    # Off by default: the window takes its new size at once. true animates it.
    # enabled = false

    [focus]
    # How the focused window stands out: "ring" (default) draws the outline
    # set up in [focus-ring]; "dim" darkens the other visible tiled windows
    # while nothing moves; "none" shows nothing.
    indicator = "ring"
    # Opacity of the dim over unfocused windows (0.0-0.5).
    dim-strength = 0.15

    [focus-ring]
    # Used when [focus] indicator = "ring".
    # A rounded outline drawn around the focused window (click-through overlay).
    enabled = true
    # Thickness in points (0-20; 0 hides it).
    width = 4
    # No ring on a maximized column or a fullscreen window.
    hide-when-maximized = true
    # Hex color; leave commented to use the Niri blue.
    # active-color = "#7fc8ff"

    [logging]
    # Minimum severity written to ~/.config/gio/gio.log: trace, debug, info,
    # warn or error. Lines below it cost nothing; use "debug" to troubleshoot.
    level = "info"

    [gestures]
    # Trackpad swipes (3-5 fingers), all off until you turn them on. macOS
    # uses three and four fingers for its own swipes by default: turn those
    # off or move them in System Settings > Trackpad > More Gestures, or both
    # act (Diagnostics lists collisions).
    # Horizontal swipe scrolls the strip with the fingers and snaps to a
    # column on release.
    scroll = false
    scroll-fingers = 3
    # Strip travel per trackpad width, in screen widths (0.1-5.0).
    scroll-sensitivity = 1.0
    # Content follows the fingers; false inverts scroll and workspace swipe.
    natural = true
    # Vertical swipe switches workspace, one per swipe.
    workspace-swipe = false
    workspace-fingers = 3
    # Swipe up toggles the workspace overview (off: macOS Mission Control
    # uses four fingers up unless moved). Not on workspace-fingers.
    overview = false
    overview-fingers = 4
    # How far a vertical swipe travels before it fires, as a fraction of the
    # trackpad height (0.05-0.5). It must be a clear up or down stroke.
    swipe-distance = 0.15

    [keybindings]
    "Alt+H" = "focus-left"
    "Alt+L" = "focus-right"
    "Alt+J" = "focus-down"
    "Alt+K" = "focus-up"
    # Also available: "switch-preset-column-width" (Alt+R),
    # "set-column-width-minus" (Alt+Minus), "set-column-width-plus" (Alt+Equal),
    # "maximize-column" (Alt+F, toggles back to the previous width),
    # "center-column" (Alt+C, scrolls the focused column to the middle),
    # "consume-or-expel-window-left" / "-right" (Alt+Shift+H / L, also Alt+[
    # and Alt+]) move the window: a stacked one gets its own column on that
    # side, a lone one joins the bottom of the neighbouring column.
    # "move-up" / "move-down" (Alt+Shift+K / J) move it within its column.
    # "fullscreen" (Alt+Shift+F; alias "fullscreen-window"; fills the display
    # under the menu bar, focusing another window restores the layout),
    # "toggle-floating" (Alt+Shift+Space; alias "toggle-window-floating").
    # "move-column-left" / "move-column-right" (Alt+Shift+Comma / Period, the
    # < and > keys) swap whole columns; "move-window-left" /
    # "move-window-right" (unbound) append the window to the neighbouring
    # column instead.
    # "toggle-overview" (Alt+O) shows every workspace of the display as a row
    # of window thumbnails (thumbnails need Screen Recording).
    # Multiple displays: "focus-monitor-left|right|up|down" (Ctrl+Alt+H / L /
    # K / J) focuses the neighbouring display; "move-column-to-monitor-..."
    # (Ctrl+Alt+Shift+H / L / K / J) sends the focused column there and
    # follows it; "move-window-to-monitor-..." (Ctrl+Alt+Cmd+H / L / K / J)
    # sends only the focused window. Unbound: "move-workspace-to-monitor-..."
    # (the whole workspace), e.g.
    # "Ctrl+Alt+Shift+Cmd+L" = "move-workspace-to-monitor-right"
    # Stacked windows: "switch-preset-window-height" (Alt+Shift+R),
    # "set-window-height-minus" / "-plus" (Alt+Shift+Minus / Equal, 10% of
    # the column; every window keeps 100 pt), "reset-window-height"
    # (Ctrl+Alt+R, equal shares again).
    # "focus-column-first" / "-last" (Alt+Home / End), "move-column-to-first"
    # / "-last" (Ctrl+Alt+Home / End). Unbound: "swap-window-left" / "-right"
    # trade places with the neighbouring column's focused window.
    # "move-column-to-workspace N" (Ctrl+Alt+1-9) and
    # "move-column-to-workspace-down" / "-up" (Ctrl+Alt+U / I) carry the whole
    # column and follow it; "move-workspace-down" / "-up" (Ctrl+Alt+Shift+U /
    # I) reorder this display's stack (named workspaces keep config order).
    # Unbound: "focus-workspace-previous" (Option+Tab is left to app
    # switchers such as AltTab), e.g. "Ctrl+Alt+Tab" = "focus-workspace-previous"
    # "expand-column-to-available-width" (Ctrl+Alt+F) fills the room the other
    # visible columns leave; "center-visible-columns" (Ctrl+Alt+C) centers them.
    # Unbound: "switch-preset-column-width-back" (the presets in reverse) and
    # "focus-window-or-workspace-down" / "-up" (the workspace below / above from
    # the column's last / first window), e.g.
    # "Alt+J" = "focus-window-or-workspace-down"
    # Unbound: "move-column-left-or-to-monitor-left" / "-right-or-to-monitor-right"
    # (from the strip's edge the column goes to the next display, entering by
    # that edge) and "focus-column-or-monitor-left" / "-right", e.g.
    # "Alt+Shift+Left" = "move-column-left-or-to-monitor-left"
    # Layouts: "toggle-workspace-layout" (Alt+Shift+T) switches the current
    # workspace between the scrolling strip and the dwindle tree (every window
    # on screen, each new one splitting the focused one); unbound:
    # "set-workspace-layout-scrolling" / "-dwindle". Dwindle only:
    # "dwindle-balance" (Alt+Shift+B, every split half and half); unbound:
    # "dwindle-toggle-split", "dwindle-swap-split",
    # "dwindle-preselect-left|right|up|down", "dwindle-preselect-clear".
    # "none" switches a combo off, defaults included (the app's Shortcuts
    # section writes these lines for you), e.g. "Alt+C" = "none"

    # Named workspaces always exist (even when empty), come first in their
    # display's stack in this order (Alt+1 is the first), and keep their
    # name across launches. icon is an SF Symbol name, color a hex color,
    # display "main" (default) or a display number (1, 2, ...; a missing
    # display falls back to the main one). layout = "scrolling" | "dwindle"
    # (unset: [layout] default-layout).
    # [[workspace]]
    # name = "Code"
    # icon = "chevron.left.forwardslash.chevron.right"
    # color = "#7fc8ff"
    #
    # [[workspace]]
    # name = "Browsers"
    # icon = "globe"

    # Rules match an app by bundle-id (preferred) or by app name, first
    # match wins. mode = "tiled" | "floating" | "fullscreen"; workspace = N
    # (index) or open-on-workspace = "<name>" (a [[workspace]] above; wins
    # over workspace). follow = "when-active" (default: go there only when
    # the app is frontmost as its window appears), "always" or "never".
    # title = "<regex>" narrows the match to window titles (case-insensitive;
    # alone it matches any app). How the window opens: default-column-width
    # (fraction <= 1 or points), open-maximized, open-on-display = N (1 is
    # the main display), open-focused = false (no focus, no follow), and
    # min-width / max-width (points) for its column.
    [[window-rules]]
    app = "Calculator"
    mode = "floating"

    # [[window-rules]]
    # bundle-id = "com.microsoft.VSCode"
    # open-on-workspace = "Code"
    # follow = "always"
    #
    # [[window-rules]]
    # app = "Safari"
    # title = "^Picture in Picture$"
    # mode = "floating"
    #
    # [[window-rules]]
    # app = "Mail"
    # default-column-width = 0.66667
    # open-on-display = 2
    # open-focused = false
    # min-width = 600
    """
}
