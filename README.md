# Gio

[![CI](https://github.com/ismaelosuna7824/gio/actions/workflows/ci.yml/badge.svg)](https://github.com/ismaelosuna7824/gio/actions/workflows/ci.yml)

Gio is a Niri-style **scrollable tiling window manager for macOS**. It arranges windows in a horizontal strip of columns and treats each display as a viewport over that strip. It works through public macOS APIs only (Accessibility, `NSWorkspace`, `CGEvent`), so **System Integrity Protection stays on** and no private compositor API is used.

> Status: pre-release (`0.1.0-alpha`, see `gioVersion` in `Sources/GioCore/Config/GioConfig.swift`). Core behavior is covered by automated tests; several live behaviors are still recorded as "live pending" in `odd/tasks/`. Read [Known limitations](docs/TESTING.md#known-limitations) before relying on it.

## What it does

- **Scrollable column layout.** Windows live in columns; the focused column is always revealed by scrolling the strip minimally (Niri rule). Windows inside a column share its height.
- **Keyboard control** (global `Alt`-based shortcuts, all rebindable in `config.toml`): focus and move windows, cycle or step column widths, maximize a column, center a column, consume/expel windows between columns, toggle floating and fullscreen.
- **Dynamic vertical workspaces.** Like Niri, each display has its own stack of workspaces with always one empty workspace at the bottom; emptied workspaces disappear once you leave them. Windows of inactive workspaces are hidden off the bottom corner of the display, and the switch is animated.
- **Automatic window admission.** Every window is classified as tile, float (with a reason), ignore or suspend. Dialogs, fixed-size windows and panels float; minimized windows stay registered and rejoin their column when restored.
- **Window rules.** `[[window-rules]]` in the config can force an app to float, tile or start on a given workspace.
- **Parking of off-viewport columns.** macOS will not place a window fully off-screen, so hidden columns keep a 1 pt sliver inside the display edge.
- **Animation.** Scroll, focus and workspace moves are animated by writing interpolated frames through Accessibility, with a configurable duration.
- **Multi-display aware** layout state (one workspace stack and viewport per display).
- **Desktop app.** One main window (Overview, Shortcuts, Layout, Focus, Animations, Rules, Logs, Diagnostics), a menu bar item, an `Alt+Space` launcher panel and an `Alt+O` workspace overview (every workspace as a row of window thumbnails). Closing the window keeps Gio running from the menu bar.
- **Config with live reload.** `~/.config/gio/config.toml` is a strict subset of TOML. Invalid config never breaks the window manager; it falls back to defaults and reports the problems.
- **Command line.** A `gio` client controls the running app over a Unix socket. A separate `gio-poc` tool exercises Accessibility directly and can restore windows after a crash.
- **Recovery.** Quitting Gio (menu, Cmd+Q, SIGTERM/SIGINT/SIGHUP) brings every parked window back on screen.

See the [User guide](docs/USER_GUIDE.md) for every shortcut and config key.

## Requirements

| Requirement | Detail |
| --- | --- |
| macOS | 13 or later (`platforms: [.macOS(.v13)]` in `Package.swift`, deployment target 13.0 in the Xcode project). |
| Toolchain | Xcode with Swift 6 (`swift-tools-version: 6.0`). The `Gio` target builds in Swift 6 mode. |
| Architecture | The Xcode `Gio` target is `arm64` only. |
| Permission | **Accessibility** for the process that runs Gio (System Settings > Privacy & Security > Accessibility). Without it Gio cannot move windows or hear shortcuts. |
| SIP | Stays enabled. |

## Build and run

Live Accessibility validation must use the **signed `Gio.app`**. macOS ties the Accessibility grant to the app's code-signing identity, and an unsigned or re-signed executable loses the grant on every rebuild.

1. Clone the repository and run `open Gio.xcworkspace`. Open the workspace, not the folder: opening the folder shows a Swift package and hides the Xcode project.
2. Select the shared **Gio** scheme.
3. Optional but recommended: sign with your own team. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` (git-ignored) and set your `DEVELOPMENT_TEAM` and a unique `PRODUCT_BUNDLE_IDENTIFIER`. Without it the app builds with ad-hoc "Sign to Run Locally" signing, and macOS may ask you to re-grant Accessibility after every build. A stable team and bundle identifier keep the grant across rebuilds. Never edit `project.pbxproj` for signing.
4. Build and run. Grant Accessibility when prompted (or use **Overview > Request Access** in the app).

Command-line build of the signed app (uses `Config/Signing.local.xcconfig` when present):

```sh
xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug \
  -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' build
```

A command-line `DEVELOPMENT_TEAM=<YOUR_TEAM_ID>` argument still overrides the xcconfig files.

Swift Package Manager (libraries, tests and the helper executables):

```sh
swift build
swift test
```

Do **not** use `swift run GioDesktop` or `swift run GioApp` to validate Accessibility behavior: they are not the signed app. `GioApp` is the legacy prototype (see [Legacy code](#legacy-code)).

The repository directory on the original author's disk is named `gio ` (with a **trailing space**). If your checkout has that name, quote every path in shell commands.

## Recovery

Gio parks off-viewport windows at the edge of a display. If Gio is killed with SIGKILL (for example Xcode's Stop button) or crashes, parked windows stay where they are. Bring them back with either:

- the shared Xcode scheme **`gio-poc-restore`** in `Gio.xcworkspace`, or
- `swift run gio-poc restore` (needs Accessibility permission for the terminal or tool that runs it).

Starting Gio again also recovers leftover parked windows that will not be tiled, and the first layout re-places tiled ones. The app's **Diagnostics > Restore All Windows** button does the same restore without quitting.

## Files Gio uses

| Path | Purpose |
| --- | --- |
| `~/.config/gio/config.toml` | User configuration. Created from a commented template by `gio setup` or **Diagnostics > Open Config File**; the app also creates it on the first edit from Settings. |
| `~/.config/gio/gio.log` | Append-only log (no window titles). `gio logs` and the Logs section read it. |
| `~/.config/gio/gio.sock` | Unix socket the `gio` CLI talks to while the app runs. |
| `~/.config/gio/gio.lock` | Single-instance lock (`flock`). |
| `~/.config/gio/themes/` | Optional theme directory. Themes are implemented in Core but not yet consumed by the UI. |

## Documentation

| Document | Audience |
| --- | --- |
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md) | Shortcuts, config reference, window rules, desktop app, CLI. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Modules, invariants, event pipeline, lifecycle, coordinate spaces (with diagrams). |
| [docs/TESTING.md](docs/TESTING.md) | Test bundles, commands, strict TDD workflow, live checklist, log recipes, limitations. |
| [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) | Workflow and step-by-step recipes to add actions, config keys, UI sections and admission rules. |
| [AGENTS.md](AGENTS.md) | Rules and pitfalls for AI coding agents. |
| `odd/tasks/*.md` | Feature documents: decisions, task IDs, commits and evidence. |

## Repository layout

```
Sources/GioCore     pure logic: state, layout, hotkeys, config, reconciler, IPC (no macOS UI/AX imports)
Sources/GioMacOS    macOS adapters: Accessibility, events, hotkey tap, displays
Sources/GioUI       SwiftUI/AppKit views and view models for the desktop app
Sources/GioDesktop  app entry point (main.swift) and SessionHost (the session)
Sources/GioCLI      `gio` command line client (target name GioCLI)
Sources/GioPOC      `gio-poc` Accessibility proof-of-concept and recovery tool
Sources/GioMac, Sources/GioApp   legacy prototype (kept for reference)
Tests/              one XCTest bundle per module
odd/tasks/          feature documents and history
```

## Legacy code

Before the Niri rewrite (branch `feat/gio-niri-rewrite`), Gio was a binary-split tiler tied to native macOS Spaces. That code still builds and has tests, but it is not part of the running app: `Sources/GioMac` and `Sources/GioApp` (targets `GioMac`, `GioApp`, tests `GioMacTests`) plus these files in `Sources/GioCore`: `TileLayout.swift`, `NativeTilingCoordinator.swift`, `SpaceWindowEligibility.swift`, `WindowFrameBridge.swift`, `WindowIdentifiers.swift`, `GapChangeTransaction.swift`, `WorkspacePreferences.swift`, `VisibleAreaDiagnostic.swift`, `DisplayUsableBounds.swift`. The pre-rewrite state is frozen at the branch `archive/pre-rewrite-niri-plan`. New work should not build on it.

## License

No license file is present in the repository.
