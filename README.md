# Gio virtual workspaces (prototype)

Gio is an experimental macOS menu-bar workspace manager using public Accessibility APIs. It parks inactive windows offscreen; it is not a compositor or a guarantee that windows are hidden. Automatic tiling is **off by default**, independently for each display.

## Run

1. On macOS, run `swift build --product GioApp`, then `swift run GioApp` from this repository.
2. Open the Gio menu and choose **Request Accessibility Access…**. Grant access in System Settings → Privacy & Security → Accessibility; reopen the app if macOS requires it.
3. Use the menu to select a workspace per connected display. After granting Accessibility permission, choose **Enable Automatic Tiling** under that display to attempt an immediate layout of eligible active windows. The menu reports the number of unsupported windows skipped; it does not mean every window was tiled. Choose a **Tiling gaps (outer / inner)** preset (0, 8, or 16 pt) to reflow enabled displays; a failed change retains the previous saved preset. If rollback of an earlier display also fails, Gio keeps a persistent divergence warning and blocks switching, tiling, gap changes, and discovery-driven tiling until Quit safely restores windows; retry Quit if restoration fails. **Disable Automatic Tiling** first restores pre-tiling frames and stays enabled if restoration fails. **Refresh Windows** discovers new windows. **Quit Gio** attempts to restore owned windows and refuses to exit if restoration fails.

A topology change pauses switching. Quit attempts to place windows within a currently connected display; if a window cannot fit, Quit is refused and ownership remains. Missing AX enumeration alone never proves closure: only a trusted retained-handle `invalidUIElement` result or process termination releases ownership. Other AX failures retain ownership and may block Quit; live behavior still needs manual validation. Retry Quit if restoration fails. The menu's last-switch timing is measured on demand for successful switches only, not a benchmark or a live multi-display result.

## Limits

Parking can leave a 1px strip. Fullscreen, non-resizable and other unsupported AX windows are not tiled. Tiling uses the display's validated visible work area to avoid the menu bar and Dock. App launch, activation and termination events trigger coalesced discovery/reflow, but Gio does not observe AXWindowCreated: new windows inside an already-running app may require **Refresh Windows**. There is no continuous polling. A failed AX write may leave a recovery warning; retry or Quit. AT-01B live AX diagnosis is still pending; offscreen switching is not confirmed fixed. Adjacent displays may block both parking corners. Accessibility can fail or be revoked; restoration and visibility are not guaranteed. No screen capture, private compositor APIs, or permission bypass are used.

## Manual validation (not yet performed)

Run these with explicit user permission on a real macOS session; leave results blank until observed. Automated mock tests do not establish live AX behavior or two-display performance.

| Scenario | Procedure | Result / measurements |
| --- | --- | --- |
| One monitor | Grant AX; enable tiling for one display, inspect skipped count and menu/Dock clearance; adjust gap; disable and inspect original frames; switch two workspaces with multiple windows, close a window, Quit and inspect placement | — |
| Two monitors | Enable tiling on only one display; inspect independent layout and skipped count, then enable the second; test a failed gap change and rollback warning with expendable windows if possible; switch independently, disconnect one display, confirm warning and Quit recovery on connected display | — |
| Idle resource cost | Measure Gio CPU % and resident memory with Activity Monitor after launch and after five minutes idle; record device and macOS version | — |
| Switch latency | Record menu last-switch ms for repeated one- and two-display switches; record hardware, window count, and range | — |
