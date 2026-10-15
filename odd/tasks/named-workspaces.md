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
- [x] NW-01 (`df82cae`) — Config model + parser/patcher: `[[workspace]]`, rule `bundle-id`,
  `open-on-workspace`, `follow`; validation (unknown workspace name → message).
- [x] NW-02 (`39455ff`) — Core: named workspaces persistent in stacks, ordering, rule routing to named
  workspace on window arrival, follow policy, rename/delete semantics (windows fall back to a
  dynamic workspace), display assignment.
- [x] NW-03 (`9a117a6`) — Desktop app "Workspaces" section: create/rename/reorder/delete, icon + color,
  assign apps (installed + running app picker with icons, bundle ids), follow policy per app,
  preview; applies via ConfigPatcher live.
- [x] NW-04 (`278a602`) — Names everywhere: Overview strip/pills, menu bar, launcher (jump to workspace by name).

Evidence NW-01/02 (route: delegated writer, opus): [[workspace]] name/icon/color/display; rules
bundle-id, open-on-workspace (unknown name = warning), follow when-active|always|never; named
workspaces persistent, first in stack, reload matches by name then position (rename), dropped name
becomes dynamic (no window loss); main display = frame at origin; follow only for windows appearing
while running (never at startup/rescan); status adds name/icon/color. Randomised test found and
fixed a real bug (stale empty workspace after removing all names). Seeded equivalence test for
configs without named workspaces. Bundles 179(44 skipped)/225/7/19/40/1217 all 0 failures (parent
re-ran); signed build OK. Gap: when-active timing for freshly launched apps unverified live.

Evidence NW-03/04 (route: delegated writer, opus): Workspaces section (cards with icon/color/name/
display, reorder, app chips with follow menu, running+installed app picker with move-from-other
confirmation, templates, delete confirmation, drafts + Apply via ConfigPatcher; rules reuse
existing per-app rule); names in Overview pills/strip/groups, menu bar rows + header, launcher
"Go to workspace". RED compile -> GREEN; bundles 228(53 skipped)/225/7/19/40/1217 all 0 failures
(parent re-ran); signed build OK. Parent reviewed PNGs (workspaces list, app picker): polished.
LIVE PENDING (persistence across restart, routing + follow, picker scan, real NSMenu).
- [x] NW-05 (`089b28d`) — Live: named workspaces work but launcher opens slowly and apps open slower
  than before. By code: launcher scanned /Applications on main at first summon + per-row full-size
  icons; registration retries 100/300/800ms; extra entry write for followed windows could wait
  0.3s. Fix: background app catalog + icon cache (refresh 0.5s after launches / >2min old), entry
  skipped for hidden target workspace, followed window enters with the switch in the same pass,
  entry writes never wait, frame-unreadable retries 30/80/200/500ms; timing lines `launcher
  summon→shown ms=`, `launcher appsReady`, `window register retry`, `window open ... total ms=`.
  Bundles 232(53 skipped)/232/7/19/40/1231 all 0 failures (parent re-ran); signed build OK.
  LIVE PENDING (needs timing sample).
- [x] NW-06 (`995fb98`, `297da3e`, `bdcdc68`) — Live timing: Chrome 368ms total (switch anim),
  Brave follow=false (not frontmost at registration), Zen 304ms before registration, bogus `pid=7`
  retries. Findings: pid=7 lines came from `swift test` writing to the REAL ~/.config/gio/gio.log
  (fixture lacked a log closure; timestamps while Gio was stopped) — Context.log now required, full
  test run leaves the user log unchanged (commit title "use the real pid" is misleading; body
  explains). Registration drops non-running pids. `window open` adds queueWait/classify. Deferred
  follow: launched <3s or activated <1.5s after placement (cancelled if user moved). Bundles
  232(53)/247/7/19/40/1241 all 0 failures (parent re-ran; log line count unchanged). LIVE PENDING.
- [x] NW-07 (`e36ced2`) — Live (2026-10-15, two displays, rule Chrome → "Browsers", typing in a Chrome
  window on the external display): the workspace changed by itself and typing jumped to the other display.
  Log: all 16 Chrome arrivals in `gio.log`/`gio.log.1` were popups (`discovery exclude ... float(notResizable)`
  < 0.3 s before `window open`; the address-bar suggestions, re-created per key); 8 had `follow=true`, each
  followed by `focus intent id=1528:2` + `cursor warped to focus id=1528:2` (the other display) and then
  `focus reveal id=1528:1 workspace=1` when the user clicked back; a click there was dropped (`focus dropped
  ... reason=focused window not under click`). Cause: `registerNew` routed every arrival by its rule, and the
  follow decision did not exclude floats (`arrivalTakesFocus` only kept them from taking the strip's
  focus). Fix: Core `arrivalPlacement(_:admissionFloat:)` (+ `FloatReason.isAdmission`): an admission float
  (dialog, floating subrole, not resizable) without a `mode = "floating"` rule drops `workspace`,
  `open-on-workspace` and `open-on-display`, so it lands on the current workspace and never follows; used by
  `registerNew` and `applyTitleRecheck`. RED: `NamedWorkspaceRoutingTests.testAPopupOfARoutedAppStays...`
  (switched to the routed workspace, followed); `testARealWindowOfTheSameAppStillFollowsItsRule` and
  `RulePlacementTests.testAWindowDiscoveryFloatedIgnores...` guard the boundary. GREEN; bundles UI 310 (53
  skipped) / Session 479 / POC 7 / Mac 19 / MacOS 95 / Core 1971, 0 failures. LIVE PENDING: type in Chrome's
  address bar on the external display.
- [x] NW-08 (commit pending) — Live (2026-10-15, after NW-07): the "music" workspace looked empty and Music
  floated behind the tiles of "Code". `gio status`: `music` 0 windows, `floatingWindows` = Music `91010:12`
  reason `dialog`; log: `discovery exclude pid=91010 app=Music float(dialog)` at the startup scan (its only
  window, so Music's main window reports a dialog subrole; [INFERENCE] from the log, the AX subrole was not
  read live). NW-07 kept every admission float off its rule's workspace. Fix: `arrivalPlacement` takes
  `appHasOtherWindows` (another managed window of the same pid): only a popup/dialog of an app that already
  has a window stays where the user is; an app's only window follows its rule, dialog or not (registration
  and title re-check). RED: `NamedWorkspaceRoutingTests.testAnAppWhoseOnlyWindowIsADialogStillOpensOn...`
  and `testAnAppsOnlyDialogArrivingLiveFollowsItsRule` failed (not routed); the Chrome popup tests now open
  Chrome's real window first (scan) and still pass; Core test covers both sides of the boundary. GREEN;
  bundles UI 310 (53 skipped) / Session 481 / POC 7 / Mac 19 / MacOS 95 / Core 1971, 0 failures. LIVE
  PENDING: restart Gio, Music lands on "music".

## Acceptance criteria
- Creating a workspace + assigning an app in the app persists in config.toml and survives restart;
  opening the app routes its window there and follows per policy.
- All bundles green; signed build OK; docs updated.

## Routes
After the in-flight niri-animations writer lands (shared config parser + session). NW-01..02 one
writer; NW-03..04 one writer.

## Progress
- 2026-09-30: document created. Waiting for NA-01..NA-04.
- 2026-09-30: NW-01 + NW-02 done, pushed. Next: NW-03 + NW-04.
- 2026-09-30: NW-03 + NW-04 done, pushed. Next: user live test.
