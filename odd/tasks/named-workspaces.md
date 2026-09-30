# Named workspaces and app assignment

## Objective
Let the user organise work from the desktop app: create named workspaces (e.g. "Code",
"Browsers", "Chat"), assign apps to them, and have Gio send each app's windows to its workspace and
take the user there — persisted across launches (configuration only, never open windows).

## Problem / request
User (2026-09-30): create workspaces from the desktop app, pick apps per workspace (VS Code → Code,
browsers → Browsers); opening such an app moves its window to that workspace and moves the user
there; configuration must persist across launches (SQLite suggested, "or reuse the existing
settings store"). Open windows are NOT restored.

## Design (Niri semantics: named workspaces + open-on-workspace)
- Persistence: `~/.config/gio/config.toml` via the existing ConfigPatcher (same store as all other
  settings; tiny, read at startup; hand-editable). No SQLite.
- `[[workspace]] name, icon (SF Symbol), color, display (optional)`; named workspaces always exist
  (never pruned when empty), ordered first in the display stack; dynamic workspaces follow.
- Assignment rules: `[[window-rules]]` gain `bundle-id` match (preferred; app name kept) and
  `open-on-workspace = "<name>"`, `follow = "when-active" | "always" | "never"` (default
  when-active: follow only if the app is frontmost/launched by the user when the window appears).
- Alt+1..9 index includes named workspaces; names shown in Overview, menu bar, launcher.

## Constraints
Pure logic in GioCore/GioSession with tests; UI in GioUI; ConfigPatcher preserves comments; config
tests use temp files; Conventional Commits, NO Co-Authored-By; push after verified batches.

## Tasks
- [ ] NW-01 — Config model + parser/patcher: `[[workspace]]`, rule `bundle-id`,
  `open-on-workspace`, `follow`; validation (unknown workspace name → message).
- [ ] NW-02 — Core: named workspaces persistent in stacks, ordering, rule routing to named
  workspace on window arrival, follow policy, rename/delete semantics (windows fall back to a
  dynamic workspace), display assignment.
- [ ] NW-03 — Desktop app "Workspaces" section: create/rename/reorder/delete, icon + color,
  assign apps (installed + running app picker with icons, bundle ids), follow policy per app,
  preview; applies via ConfigPatcher live.
- [ ] NW-04 — Names everywhere: Overview strip/pills, menu bar, launcher (jump to workspace by name).

## Acceptance criteria
- Creating a workspace + assigning an app in the app persists in config.toml and survives restart;
  opening the app routes its window there and follows per policy.
- All bundles green; signed build OK; docs updated.

## Routes
After the in-flight niri-animations writer lands (shared config parser + session). NW-01..02 one
writer; NW-03..04 one writer.

## Progress
- 2026-09-30: document created. Waiting for NA-01..NA-04.
