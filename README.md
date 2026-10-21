# Gio

[![CI](https://github.com/ismaelosuna7824/gio/actions/workflows/ci.yml/badge.svg)](https://github.com/ismaelosuna7824/gio/actions/workflows/ci.yml)

Gio is a Niri-style **scrollable tiling window manager for macOS**. It arranges windows in a horizontal strip of columns and treats each display as a viewport over that strip. It moves windows through public macOS APIs (Accessibility, `NSWorkspace`, `CGEvent`); the only private call it makes reads the trackpad's finger positions for gestures (see [Private APIs](#private-apis)). **System Integrity Protection stays on**; Gio injects nothing into other processes or the Dock.

> Status: pre-release. The version comes from the release tag (`MARKETING_VERSION`, see [RELEASING](docs/RELEASING.md)); local and SwiftPM builds report the last tag or `0.0.0-dev`. Core behavior is covered by automated tests; several live behaviors are still recorded as "live pending" in `odd/tasks/`. Read the [Known limitations](docs/USER_GUIDE.md#known-limitations) before relying on it (developer detail: [TESTING](docs/TESTING.md#known-limitations)).

## Install

Gio needs a Mac with **Apple silicon** and **macOS 13 or later**. The smooth-motion renderer, the overview thumbnails and the close ghost use Screen Recording, which needs macOS 14 or later (see [Why Screen Recording](#why-screen-recording)).

1. Download **[Gio.dmg](https://github.com/ismaelosuna7824/gio/releases/latest/download/Gio.dmg)** (the newest release). Each release on the [Releases page](https://github.com/ismaelosuna7824/gio/releases) also has `Gio-<version>.dmg` with a checksum: `shasum -a 256 -c Gio-<version>.dmg.sha256` in the download folder.
2. Open the DMG and drag **Gio** onto **Applications**. Run it from `/Applications`: a copy opened straight from the DMG or from Downloads cannot update itself.
3. Open Gio. The app is **not notarized yet**, so the first time macOS refuses with a dialog saying Apple could not verify Gio is free of malware. Click **Done** (not **Move to Trash**).
4. Open **System Settings > Privacy & Security**, scroll to the message about Gio being blocked and click **Open Anyway**, then confirm with your password. On macOS 15 and later this is the only way; the old right-click **Open** shortcut no longer bypasses the check. You do this once: later versions install through Gio's own updater.
5. Grant **Accessibility** when Gio's first-run guide asks (or turn Gio on in System Settings > Privacy & Security > Accessibility). Without it Gio cannot move windows or hear shortcuts.
6. Optional: grant **Screen Recording** (from the first-run guide, or **Request access** in the app's Overview or Diagnostics), then **relaunch Gio**: macOS applies the grant only on the next launch. Without it Gio still tiles, but windows stutter as they move.

Then read [First steps](docs/USER_GUIDE.md#first-steps) and, on a non-US keyboard, [Keyboard layouts](docs/USER_GUIDE.md#keyboard-layouts): Gio's default shortcuts take `Option` combos that type characters such as `@`, `#`, `|`, `[` and `]` on many layouts.

## Uninstall

1. **Quit Gio** (menu bar item > **Quit Gio**). Quitting brings every window Gio parked back on screen.
2. If you turned on **Open at Login**, turn it off first (Overview > Status in the app), or remove Gio in System Settings > General > Login Items.
3. Delete the app and its files:

   ```sh
   rm -rf /Applications/Gio.app
   rm -rf ~/.config/gio                                  # config, log, socket and lock
   rm -rf ~/Library/Logs/Gio                             # the updater's log
   rm -rf ~/Library/Caches/dev.gio.windowmanager         # caches: app icons, apps' minimum window sizes
   defaults delete dev.gio.windowmanager                 # first-run guide and update settings
   ```

4. Remove the permissions:

   ```sh
   tccutil reset Accessibility dev.gio.windowmanager
   tccutil reset ScreenCapture dev.gio.windowmanager
   ```

`dev.gio.windowmanager` is the bundle identifier of the released app. A build you signed yourself uses the `PRODUCT_BUNDLE_IDENTIFIER` from your `Config/Signing.local.xcconfig`.

## Privacy

- **No telemetry.** Gio sends no analytics, usage data or crash reports.
- **Update checks** ask GitHub's public API (`api.github.com`) for the releases of `ismaelosuna7824/gio`, anonymously, with a `Gio/<version>` user agent; an update downloads the release's DMG from GitHub. Turn the automatic check off in **Diagnostics > Updates**.
- **Logs never contain window titles**: only numeric window IDs, counts, timings and app names. They stay on your Mac (`~/.config/gio/gio.log`).
- **Window images** captured for motion and the overview (Screen Recording) stay in memory; Gio never writes them to disk or sends them anywhere.
- **Report a Problem** (Diagnostics) saves a zip in `~/Downloads` and opens a prefilled GitHub issue in your browser (with the last warning and error log lines); nothing reaches GitHub until you press **Submit** there, and the zip only if you attach it.

## What it does

- **Scrollable column layout.** Windows live in columns; the focused column is always revealed by scrolling the strip minimally (Niri rule). Windows inside a column share its height.
- **Dwindle layout per workspace.** Any workspace can switch (`Alt+Shift+T`) to a Hyprland-style dwindle tree: every window on screen, each new one splitting the focused one, with split toggles, swaps, preselection and balance; focus, moves, sizes and the edge crossing keep working there. See [Dwindle layout](docs/USER_GUIDE.md#dwindle-layout).
- **Keyboard control** (global `Alt`-based shortcuts, all rebindable or removable in the app's **Shortcuts** section or `config.toml`): focus and move windows, cycle or step column widths, maximize a column, center a column, consume/expel windows between columns, toggle floating and fullscreen.
- **Dynamic vertical workspaces.** Like Niri, each display has its own stack of workspaces with always one empty workspace at the bottom; emptied workspaces disappear once you leave them. Windows of inactive workspaces are hidden off the bottom corner of the display, and the switch is animated.
- **Automatic window admission.** Every window is classified as tile, float (with a reason), ignore or suspend. Dialogs, fixed-size windows and panels float; minimized windows stay registered and rejoin their column when restored.
- **Window rules.** `[[window-rules]]` in the config can force an app to float, tile or start on a given workspace.
- **Parking of off-viewport columns.** macOS will not place a window fully off-screen, so hidden columns keep a 1 pt sliver inside the display edge. Hiding and revealing windows goes through Accessibility.
- **Animation.** Scroll, focus and workspace moves animate with a Niri-style spring (or an `ease-out` curve). By default the real windows move once and an overlay slides images of them at the display's refresh rate, so slow apps keep up; this needs Screen Recording (see [Why Screen Recording](#why-screen-recording)). The alternative `ax` renderer moves the real windows through Accessibility on every frame.
- **Multi-display aware** layout state (one workspace stack and viewport per display), niri's monitor actions, and optional edge crossing: `move-column-left/right-or-to-monitor-*` and `focus-column-or-monitor-*` carry a column past the strip's edge to the next display; with `[behavior] move-crosses-monitor-at-edge`, the window move (`Alt+Shift+H/J/K/L`, OmniWM's Move Edge) sends the window and the column move (`Alt+Shift+<` / `>`) the column.
- **Trackpad gestures.** Swipe left or right with three fingers to scroll the strip: it follows the fingers and settles on a column with the swipe's speed, like niri. Swipe up or down to switch workspace; optionally swipe up with four fingers for the workspace overview. macOS's own three- and four-finger swipes must be moved or turned off; Gio says which collide (see [Private APIs](#private-apis) and the [User guide](docs/USER_GUIDE.md#trackpad-gestures)).
- **Desktop app.** One main window (Overview, Shortcuts, Workspaces, Layout, Focus, Animations, Rules, Logs, Diagnostics), a menu bar item, an `Alt+Space` launcher panel and an `Alt+O` workspace overview (every workspace as a row of window thumbnails). Closing the window keeps Gio running from the menu bar.
- **Config with live reload.** `~/.config/gio/config.toml` is a strict subset of TOML. Invalid config never breaks the window manager; it falls back to defaults and reports the problems.
- **Command line (from a source checkout).** A `gio` client controls the running app over a Unix socket, and a separate `gio-poc` tool exercises Accessibility directly and can restore windows after a crash. Neither is in the DMG: build them with SwiftPM (see [Build and run](#build-and-run-from-source)).
- **Recovery.** Quitting Gio (menu, Cmd+Q, SIGTERM/SIGINT/SIGHUP) brings every parked window back on screen, and a guardian helper does the same if Gio crashes or is killed (see [Recovery](#recovery)).

See the [User guide](docs/USER_GUIDE.md) for every shortcut and config key.

## Requirements

| Requirement | Detail |
| --- | --- |
| macOS | 13 or later (`platforms: [.macOS(.v13)]` in `Package.swift`, deployment target 13.0 in the Xcode project). Screen Recording features need 14 or later. |
| Toolchain (building from source) | Xcode with Swift 6 (`swift-tools-version: 6.0`). The `Gio` target builds in Swift 6 mode. |
| Architecture | Apple silicon: the Xcode `Gio` target and the released app are `arm64` only. |
| Permission | **Accessibility** for the process that runs Gio (System Settings > Privacy & Security > Accessibility). Without it Gio cannot move windows or hear shortcuts. |
| Permission for smooth motion | **Screen Recording**, required by the default snapshot renderer, the overview thumbnails and the optional close ghost (macOS 14 or later); relaunch Gio after granting it. Without it Gio still tiles, but windows stutter as they move; see below. |
| SIP | Stays enabled. |

### Why Screen Recording

Apps redraw at their own pace, and some are slow (WhatsApp, Music, Xcode). Moving the real windows through Accessibility on every frame makes those apps lag behind the rest and jump. The default renderer (`[animations] renderer = "snapshot"`) avoids that: it moves each real window once, slides images of them in an overlay at the display's refresh rate, and removes the overlay only once the windows that came into view have painted. Every app then moves at the same speed, however slowly it repaints; during the slide the windows show their content as of the last capture.

Capturing those images is what macOS calls Screen Recording (ScreenCaptureKit, macOS 14 or later). The same captures give the `Alt+O` overview its live thumbnails and the optional close ghost (`[animations.window-close] ghost = true`, off by default) the last image a closed window fades out from.

- **Without it, or on macOS 13**, Gio still works: it falls back to the Accessibility motion (the log shows `renderer effective=ax reason=screen-recording-missing`), so slow apps move at their own pace, the overview shows app icons and closed windows do not fade.
- **Privacy.** The images stay in memory; Gio never writes them to disk or sends them anywhere. Window titles never reach the log.
- **Granting it.** Gio never asks at launch. Use **Request access** in the app's Overview or Diagnostics, then relaunch Gio: macOS usually applies a new grant only on the next launch.

### Private APIs

Trackpad gestures need the fingers' positions, which no public API reports. When this macOS has them, Gio uses:

- **MultitouchSupport** (`MTDeviceCreateList`, `MTDeviceStart`, `MTDeviceStop`, `MTRegisterContactFrameCallbackWithRefcon`, `MTUnregisterContactFrameCallback`, from the private `MultitouchSupport` framework): the raw finger positions of the built-in trackpad and Magic Trackpads, for the trackpad gestures. Gio only reads them; it does not intercept or swallow any scroll or gesture event, so macOS's own gestures keep working (and must be moved where they collide). Without these symbols, or with every gesture off in `[gestures]`, the trackpad devices are not opened; the log says why (`gestures available=... reason=...`) and so does **Diagnostics > Gestures**.

The symbols are loaded at runtime (`dlopen`/`dlsym`), never linked. Windows themselves always move through Accessibility. Gio also switches an app's `AXEnhancedUserInterface` attribute off while it writes that app's windows and back on right after (assistive apps such as VoiceOver set it, and it makes Chromium and Electron apps slow to move).

## Build and run (from source)

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

Swift Package Manager (libraries, tests and the helper executables, among them the `gio` client, target `GioCLI`, and `gio-poc`; they are not part of the DMG):

```sh
swift build
swift test
```

Do **not** use `swift run GioDesktop` or `swift run GioApp` to validate Accessibility behavior: they are not the signed app. `GioApp` is the legacy prototype (see [Legacy code](#legacy-code)).

The repository directory on the original author's disk is named `gio ` (with a **trailing space**). If your checkout has that name, quote every path in shell commands.

## Recovery

Gio parks off-viewport windows at the edge of a display. It brings them back by itself:

- **On quit.** Quitting Gio (menu bar > **Quit Gio**, Cmd+Q, SIGTERM/SIGINT/SIGHUP, or an update) restores every parked window.
- **After a crash.** Gio starts a small guardian helper (a second `Gio --guardian` process, no icon). If Gio crashes or is killed (Force Quit, `kill -9`, Xcode's Stop button), the guardian brings the parked windows back within about a second; the log shows `guardian restore applied=N`.

If windows are still missing (power loss, or a guardian that could not run):

1. **Open Gio again.** At startup it recovers leftover parked windows that will not be tiled, and the first layout re-places the tiled ones.
2. Or, while Gio runs, **Diagnostics > Restore All Windows** brings every parked window on screen without quitting (tiling stays on, so the next layout change parks them again).
3. From a source checkout only: `swift run gio-poc restore` (needs Accessibility permission for the terminal that runs it), or the shared Xcode scheme **`gio-poc-restore`** in `Gio.xcworkspace`.

## Files Gio uses

| Path | Purpose |
| --- | --- |
| `~/.config/gio/config.toml` | User configuration. Created from a commented template by **Diagnostics > Open Config File** (or `gio setup` from a source checkout); the app also creates it on the first edit from Settings. |
| `~/.config/gio/gio.log` | Append-only log (no window titles), rotated at about 1 MB to `gio.log.1`. The Logs section (and `gio logs`) read it. |
| `~/.config/gio/gio.sock` | Unix socket the `gio` CLI (source checkout) talks to while the app runs. |
| `~/.config/gio/gio.lock` | Single-instance lock (`flock`). |
| `~/.config/gio/themes/` | Optional theme directory. Themes are implemented in Core but not yet consumed by the UI. |
| `~/Library/Logs/Gio/update.log` | The updater helper's log (paths and steps only). |
| `~/Library/Caches/dev.gio.windowmanager/launcher-icons.plist` | The launcher's cache of app icons (the folder is the app's bundle identifier). |
| `~/Library/Caches/dev.gio.windowmanager/app-minimum-sizes.json` | The minimum widths apps enforce (WhatsApp, Figma...), so their windows are laid out at that width from the first layout after a launch. Delete it to forget them. |

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
