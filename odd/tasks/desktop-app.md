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
Not in scope (2026-09-29): editing shortcuts by recording keys (view-only per user request).
Superseded by DA-07 (user rule 2026-10-08: "todo se debe de controlar desde la app sin
necesidad de modificar el config.toml").

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
- [ ] DA-07 — Everything controllable from the app (user rule 2026-10-08: "todo se debe de
  controlar desde la app sin necesidad de modificar el config.toml"). The two config keys
  without a control were `[keybindings]` (Shortcuts was view-only) and `[logging] level`
  (the Logs level chips only filter the view). Themes stay parsed-but-unused (out of scope).
  Decisions:
  - **Unbind value `"none"`** (`"Alt+C" = "none"`): removes whatever the combo did,
    defaults included; the last line for a combo wins. Parsed into `GioConfig.unboundKeys`
    (normalized against `keybindings`, so order never matters downstream); `makeDispatcher`
    and `shortcutCatalog`/`effectiveHotkeyBindings` drop those combos; `ShortcutEntry`
    gains `action` (representative) and `removedDefaults` (shown as **Removed**).
  - **Edits (pure, Core `Hotkeys/KeybindingEditing.swift`):** Add and Replace are the same
    edit (`.setKeybinding(combo, .action)`; one action per combo, so the other action loses
    it). Remove writes `"none"` when the combo has a default (deleting an override line would
    revive the default) and deletes the line for a config-only combo. Reset deletes every
    line touching the family: its own bindings, `"none"` on its defaults, and its defaults
    rebound elsewhere. The patcher matches `[keybindings]` lines by parsed combo (any
    spelling), rewrites the first match in place (keeps its comment), drops duplicates, and
    inserts quoted keys after the last binding (before the template's comment block).
  - **Validation** (`checkShortcut`): a modifier, a key in `supportedKeyNames`, not
    `Alt+Space`; a used combo reports the other action and its source (Replace).
  - **Apply convention:** each row change applies immediately with a toast naming it
    ("Added ⌃⌥F9 to Center column"), like Rules (discrete add/remove through a sheet), not
    the draft+Apply bar of Layout/Animations: a single binding has nothing to batch or
    preview, and a pending unsaved binding would be confusing while hotkeys run.
    `ApplyToast(feedback:successTitle:)` and an `applyToastOverlay` modifier carry it.
  - **Suspension seam:** `routeHotkey(_:dispatcher:suspended:)` (Core, pure) is the whole
    `handleCombo` decision; `HotkeyGate` (Core, locked flag) is owned by `SessionHost` and
    set through `DesktopActions.setHotkeysSuspended`. The tap stays installed; while
    suspended every combo passes through unswallowed (the launcher's too) so the recorder's
    local `NSEvent` monitor receives it. `DesktopModel.suspendHotkeys/resumeHotkeys` are
    idempotent; the sheet resumes on save, cancel, Esc, disappear and app resign-active, and
    hiding the main window resumes. `HotkeyTap` only gained the shared
    `hotkeyKeyName(forKeyCode:)` the recorder uses to name `NSEvent` keycodes.
  - **Workspace families** (`workspace N`, `move-to-workspace N`) pick the number in the
    recorder; their long `⌥1…⌥9` rows remove through a menu.
  - **Log file level** picker lives in the Logs header (the page that tails the file it
    tunes), writes `[logging] level` via `logLevelEdits` and reloads with a toast; the
    view's chips are labelled **Show** and say they filter the view only.
  - `SessionSnapshot.keybindings` removed (the catalog reads `snapshot.config`).
  Files: `GioCore/Hotkeys/KeybindingEditing.swift` (new), `ShortcutCatalog.swift`,
  `Config/{GioConfig,ConfigParser,ConfigPatcher,SettingsForms,ConfigTemplate}.swift`,
  `GioMacOS/Hotkeys/HotkeyTap.swift`, `GioUI/ShortcutEditing.swift` (new),
  `GioUI/{ShortcutsView,LogsView,DesktopModel,AdvancedPresentation}.swift`,
  `GioUI/Settings/{SettingsComponents,SettingsPresentation}.swift`,
  `GioDesktop/{SessionHost,main}.swift`.
  Evidence: RED `swift test --filter GioCoreTests.KeybindingEditingTests` failed to compile
  (`cannot find 'routeHotkey'`, `'HotkeyGate'`, `'checkShortcut'`, `'addShortcutEdits'`,
  `'configActionName'`, `'logLevelEdits'` ...); RED `swift build --build-tests` failed for
  `hotkeyKeyName` (HotkeyKeyTableTests) and `ShortcutRowModel` (ShortcutEditingTests).
  GREEN: KeybindingEditingTests 28, ShortcutEditingTests 17, the key-table test, updated
  AdvancedPresentationTests. Full `swift test` 2026-10-08: GioUITests 269 (53 skipped),
  GioSessionTests 326, GioPOCTests 7, GioMacTests 19, GioMacOSTests 48, GioCoreTests 1369,
  0 failures; `git diff --check` clean. Visual check: throwaway opt-in snapshots (edited
  Shortcuts page light/dark with config tag, Removed line, Reset, range menu and toast;
  recorder in conflict, invalid and workspace states; Logs header with the picker) were
  inspected, led to aligned row actions, a page background on the sheet and a non-truncating
  Logs header, then deleted. Signed build: not run here. Uncommitted. LIVE PENDING
  (TESTING.md 10b): recording while the tap runs (a bound combo must reach the recorder, not
  fire), the recorder sheet getting key focus, resume after Cmd+Tab and window close, and the
  live reload of a rebound key and of the log level.

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
- 2026-10-08: DA-07 code-complete (editable Shortcuts with recorder and `"none"` unbind, Log
  file level picker). Uncommitted. Next: signed build and live check 10b.
