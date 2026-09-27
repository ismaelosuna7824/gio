# Gio virtual workspaces (prototype)

Gio is an experimental macOS menu-bar workspace manager using public Accessibility APIs. It parks inactive windows offscreen; it is not a compositor or a guarantee that windows are hidden.

## Run

1. On macOS, run `swift build --product GioApp`, then `swift run GioApp` from this repository.
2. Open the Gio menu and choose **Request Accessibility Access…**. Grant access in System Settings → Privacy & Security → Accessibility; reopen the app if macOS requires it.
3. Use the menu to select a workspace per connected display. **Refresh Windows** discovers new windows. **Quit Gio** attempts to restore owned windows and refuses to exit if restoration fails.

A topology change pauses switching. Quit attempts to place windows within a currently connected display; if a window cannot fit, Quit is refused and ownership remains. Missing AX enumeration alone never proves closure: only a trusted retained-handle `invalidUIElement` result or process termination releases ownership. Other AX failures retain ownership and may block Quit; live behavior still needs manual validation. Retry Quit if restoration fails. The menu's last-switch timing is measured on demand for successful switches only, not a benchmark or a live multi-display result.

## Limits

Parking can leave a 1px strip. Fullscreen and other unsupported AX windows are not supported. Adjacent displays may block both parking corners. Accessibility can fail or be revoked; restoration and visibility are not guaranteed. No screen capture, private compositor APIs, or permission bypass are used.

## Manual validation (not yet performed)

Run these with explicit user permission on a real macOS session; leave results blank until observed. Automated mock tests do not establish live AX behavior or two-display performance.

| Scenario | Procedure | Result / measurements |
| --- | --- | --- |
| One monitor | Grant AX; switch two workspaces with multiple windows, close a window, Quit and inspect placement | — |
| Two monitors | Move windows on each display, switch independently, disconnect one display, confirm warning and Quit recovery on connected display | — |
| Idle resource cost | Measure Gio CPU % and resident memory with Activity Monitor after launch and after five minutes idle; record device and macOS version | — |
| Switch latency | Record menu last-switch ms for repeated one- and two-display switches; record hardware, window count, and range | — |
