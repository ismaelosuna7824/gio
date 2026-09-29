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
- [ ] DA-01 — App shell: single main window with sidebar sections; opens on launch and
  from the menu bar ("Open Gio"); closing hides it and the app keeps running in the menu
  bar (activation policy regular while the window is open, accessory when closed);
  Debug window and its auto-open removed; `runTileReflow` button removed from the UI.
- [ ] DA-02 — Shortcuts section: every action with its current binding(s) (defaults +
  config overrides), description, category, source (default/config); searchable.
- [ ] DA-03 — Overview section: session status, Accessibility permission (with request
  button), workspaces, and windows with mode/reason (tiled/floating/minimized/hidden).
- [ ] DA-04 — Settings sections: layout (gaps, padding, default width, presets), animations
  (enabled, duration), focus options, window rules; edits patch config.toml in place and
  trigger reload; validation messages shown inline.
- [ ] DA-05 — Logs & diagnostics section: live log viewer with level filter, doctor facts,
  actions (reload config, restore all windows, open config file, quit).

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
