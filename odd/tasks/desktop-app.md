# Unified desktop app (phase 3 of live-issues plan)

## Objective
One real desktop app: a single main window where everything about Gio is visible and
configurable (status, shortcuts, settings, rules, logs). Closing the window keeps Gio
running from the menu bar, like other menu-bar apps; the menu bar item reopens it.

## Problem (diagnosis 2026-09-29)
- Gio.app is an LSUIElement agent with three loose surfaces: menu bar item, a separate
  Launcher NSWindow, and a "Gio Debug" NSWindow that auto-opens without AX permission.
- Preferences opens `~/.config/gio/config.toml` in an external editor; no settings UI.
- The Debug console's "Tile Main Display" runs a throwaway `runTileReflow` that bypasses
  and can fight the live SessionHost.
- No place lists the available actions and their shortcuts (35 default bindings now).

## Why
User (2026-09-29): "la desktop app esta muy confusa porque abre muchas cosas... la idea es
que todo se pueda configurar en esta desktop app... cuando se minimice que se pueda seguir
ejecutando en modo app bar" and "pon todos los controles que se pueden usar y los shortcuts
para que se puedan ver y sepas cuales estan disponibles y que hace cada uno".

## Scope (authorized)
Main window shell + menu-bar lifecycle, shortcuts reference, status/windows/workspaces
overview, settings editing written back to config.toml, logs/diagnostics. The Alt+Space
launcher stays a summoned panel (it is a launcher, not configuration).
Not in scope: editing shortcuts by recording keys (view-only per user request).

## Constraints
- SwiftUI for the window content (AppKit host), per plan §3; the app talks to the session
  through existing in-process APIs/IPC, never bypassing SessionHost.
- Pure models (shortcut catalog, settings patcher) in GioCore/GioUI with XCTest.
- Config writes preserve unrelated lines and comments; invalid input never breaks the WM.
- Conventional Commits, NO Co-Authored-By. Push/PR not authorized. Quote trailing-space path.

## Tasks
- [x] DA-01 (`d9744bd`) — App shell: single main window with sidebar sections; opens on launch and
  from the menu bar ("Open Gio"); closing hides it and the app keeps running in the menu
  bar (activation policy regular while the window is open, accessory when closed);
  Debug window and its auto-open removed; `runTileReflow` button removed from the UI.
- [x] DA-02 (`49d1e27`) — Shortcuts section: every action with its current binding(s) (defaults +
  config overrides), description, category, source (default/config); searchable.
- [x] DA-03 (`5c87689`) — Overview section: session status, Accessibility permission (with request
  button), workspaces, and windows with mode/reason (tiled/floating/minimized/hidden).
- [x] DA-04 (`1bca3d4`) — Settings sections: layout (gaps, padding, default width, presets), animations
  (enabled, duration), focus options, window rules; edits patch config.toml in place and
  trigger reload; validation messages shown inline.
- [x] DA-05 (`143b294`) — Logs & diagnostics section: live log viewer with level filter, doctor facts,
  actions (reload config, restore all windows, open config file, quit).
- [ ] DA-06 — Open at Login (user request 2026-10-08: "agregar la opción de que se inicie la
  app cuando inicia la Mac"). Decisions: macOS owns the state (`SMAppService.mainApp`,
  macOS 13 = deployment target), so there is no config key; the switch lives in Overview >
  Status next to the permissions (system integration, the "General" sidebar group);
  `LoginItemModel` re-reads the system status after every change and on the Overview poll,
  so a change in System Settings shows up; `requiresApproval` keeps the switch on with an
  **Open Login Items…** button; outside an app bundle the switch is disabled. A login launch
  (`keyAELaunchedAsLogInItem` in the launch Apple event) does not open the main window
  unless Accessibility is missing (`opensMainWindowAtLaunch`, GioCore). Files:
  `GioCore/Commands/LaunchAtLogin.swift`, `GioMacOS/System/LoginItem.swift`,
  `GioUI/LoginItem.swift`, `GioUI/OverviewView.swift`, `GioDesktop/main.swift`. RED:
  `swift build --build-tests` failed (`cannot find 'opensMainWindowAtLaunch'`, then
  `LoginItemService`, `LoginItemModel`, `loginItemPresentation` unknown) for
  `LaunchAtLoginTests` (3) and `LoginItemTests` (4); GREEN. Visual check: opt-in snapshots
  of the Status card (off light, on dark, approval pending) rendered with `GioSwitch` (the
  first render used a plain `Toggle`, which `ImageRenderer` cannot draw). LIVE PENDING
  (TESTING.md 13b): registration, approval, the quiet login launch, and whether the launch
  Apple event still carries `keyAELaunchedAsLogInItem` for `SMAppService.mainApp`
  launches on this macOS [INFERENCE from community practice, not observed].

Evidence DA-01..03 (route: one delegated writer): MainWindow (NavigationSplitView) in GioUI,
policy .regular while visible / .accessory when closed, Gio pid excluded from discovery,
Debug window + Tile Main Display removed, ShortcutCatalog exhaustive switch over HotkeyAction,
OverviewModel. Fixed latent bug: SessionHost used defaults-only HotkeyDispatcher, so
`[keybindings]` overrides never applied; now config.makeDispatcher() at start + reload.
RED (compile) -> GREEN each task; 502 executed 0 failures (parent spot-check); signed build
OK; pbxproj unchanged. Gaps: 2-3s polling refresh; launcher shadowing not shown. LIVE PENDING.
Review: UNAVAILABLE.

Evidence DA-04/05 (route: one delegated writer): ConfigPatcher (text-preserving, round-trip
parse gate, atomic temp+rename, template on missing file), Layout/Animations/Focus/Rules
views with Apply -> in-process reload; LogFilter + tail reader, Diagnostics (facts + Reload,
Restore All Windows, Open Config File, Quit). RED (compile) -> GREEN; 540 executed 0 failures
(parent spot-check); signed build OK; pbxproj unchanged. Gaps: rule block comments lost on
update; rules match app name only; invalid existing config blocks edits; views untested
beyond compile. LIVE PENDING. Review: UNAVAILABLE.

## Acceptance criteria
- Only one Gio window ever opens (plus the summoned launcher); closing it leaves the menu
  bar item and tiling running; reopening restores it.
- All 35+ actions are listed with correct live bindings and descriptions.
- Settings edits take effect live without restarting Gio.
- `swift test` green; signed Gio build OK; `git diff --check` clean.

## Applicable checks
- TDD: STRICT ON (user global CLAUDE.md). Runner `swift test` (XCTest).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: UNAVAILABLE (gentle-ai trims trailing-space path; user chose continue without reporting).

## Delivery
Strategy `ask-on-risk`; one work-unit commit per task on `feat/gio-niri-rewrite`.

## Routes
- DA-01..DA-03: one delegated writer. DA-04..DA-05: one delegated writer after.

## Progress
- 2026-09-29: document created (niri-controls user-accepted live: "si parece mejor"). Next: DA-01..DA-03.
- 2026-09-29: DA-01..DA-03 done. Next: DA-04..DA-05 (route: delegated writer).
- 2026-09-29: DA-04 + DA-05 done. All tasks code-complete. Next: user live test.
