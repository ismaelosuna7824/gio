# Hardening: close documented gaps + crash guardian

## Objective
Make the behaviour match what Gio promises: keyboard focus really moves, every
configurable option and key works, CLI/launcher do what they say, only the reconciler
writes windows, and windows come back even when Gio dies abruptly.

## Problem (docs verification 166d7a7, 2026-09-29)
- `SessionHost` passes `focused: nil` to the reconciler: Alt+H/L scroll the strip but never
  focus/raise the target window (keyboard focus stays on the old app).
- `SessionHost.applyPrepositions` writes frames directly (breaks "only WindowReconciler writes").
- HotkeyTap knows a fixed key table (H J K L R F C, 1-9, Space, Minus, Equal, brackets);
  config bindings on other keys parse but never fire.
- `focus-follows-mouse`, `mouse-follows-focus`, `center-focused-column`, themes: parsed, unused.
- `gio restart` parses but does nothing; launcher claims window search but only lists apps.
- A crash / SIGKILL / Force Quit leaves windows parked or hidden (bac43c6 crash showed it).

## Why
User approved (2026-09-29, "si dale") fixing the documented findings, starting with focus,
and the guardian process for abrupt exits.

## Scope (authorized)
HD-01..HD-07 below. Themes stay documented as unsupported (no border/overlay renderer
exists); signing team stays a documented per-collaborator step.

## Constraints
- Pure logic in GioCore with XCTest; wiring thin; only WindowReconciler writes; Gio never
  manages its own pid. Conventional Commits, NO Co-Authored-By. Quote trailing-space path.
- Push after each verified batch is authorized to origin (github-personal) on
  `feat/gio-niri-rewrite` only; no PR/merge.

## Tasks
- [x] HD-01 (`e0a2275`) — Keyboard focus follows Gio focus: hotkey/IPC focus and move actions focus and
  raise the target window through the reconciler (not for click adoption or passive events).
- [x] HD-02 (`3b81b60`) — Workspace-switch prepositions go through the reconciler (no direct writes).
- [x] HD-03 (`953d6c6`) — Full key table in HotkeyTap (letters, digits, F1-F12, arrows, punctuation,
  Tab/Return/Escape/Space/Delete) so any valid config binding fires.
- [x] HD-04 (`3451fd1`) — Wire `mouse-follows-focus`, `focus-follows-mouse`, `center-focused-column`
  (never/always/on-overflow, Niri semantics).
- [x] HD-05 (`954b94d`) — `gio restart` restarts the session (restore, relaunch, exit) over IPC.
- [x] HD-06 (`c1671dc`) — Launcher searches managed windows too; choosing one focuses and reveals it.
- [x] HD-07 (`14369e3`) — Guardian process: launched by Gio, watches Gio's pid, restores off-screen
  windows if Gio exits without a clean shutdown (crash, SIGKILL, Force Quit).
- [x] HD-08 (`ef3d9cb`) — Test bundles never write the real log: under XCTest the global
  `GioLog` defaults to a per-process temp file (`$TMPDIR/gio-xctest-<pid>.log`).

Evidence HD-01..03 (route: one delegated writer): FocusIntent table (focus/move/workspace/
fullscreen/consume-expel/IPC carry intent; width/maximize/center/floating don't), applied on
final exact pass after writes, echo guard 2s/0.6s, mouse-down cancels; reconciler
`preposition(frames:)`; shared KeyNames (72) + ANSI tapKeyCodes, unknown key -> config message.
RED (compile) -> GREEN each; bundles 12/7/19/23/564 all 0 failures (parent re-ran); signed
build OK. LIVE PENDING. Review: UNAVAILABLE.

Evidence HD-04..06 (route: one delegated writer): center-focused-column enum (bool back-compat:
true=always), warp + hover focus pure decisions (keyboard-only centering/warp, 100ms hover,
layer-0 same-pid hit test, 0.4s post-warp suppression); restart replies then restores,
relaunches with --after-restart lock wait; launcher mixes apps + windows, focusWindow path.
RED -> GREEN; bundles 20/7/19/23/602 all 0 failures (parent re-ran); signed build + GioCLI OK.
User-visible: user's config has center-focused-column = true and mouse-follows-focus = true,
which now take effect. LIVE PENDING. Review: UNAVAILABLE.

Evidence HD-07 (route: one delegated writer): guardian = same executable with `--guardian <pid>`
detected before NSApplication setup, stdin pipe protocol (`clean` -> exit; EOF without clean ->
confirm parent dead -> no-daemon restore), closes inherited fds 3..255; 15 tests RED -> GREEN;
bundles 20/7/19/23/616 all 0 failures (parent re-ran); signed build OK; smoke test clean path
exit 0 in 0.33s. Parent fixed TESTING.md kill command (`pgrep -x Gio` also matches the guardian).
TCC inheritance assumption LIVE PENDING. Review: UNAVAILABLE.

Evidence HD-08 (2026-10-08, route: one delegated writer): the user's real `~/.config/gio/gio.log`
held test fixture lines (`app=pid30 kind=timeout` 68x, `app=pid20` 12x, `app=pid10` 2x): suites
that log before any suite sets `GioLog.logFilePath` appended to the production default. Fix in
`GioLog`: `defaultLogFilePath` is resolved once per process by
`resolveDefaultLogFilePath(home:temporaryDirectory:underXCTest:pid:)`; `isRunningUnderXCTest`
is `XCTestConfigurationFilePath` in the environment or `NSClassFromString("XCTestCase")`, so no
bundle or new test file can forget it. Suites that test the file sink (`GioLogTests`,
`LogSinkTests`, `ReconcileFailureTests`) keep their explicit temp paths.
`TestLogIsolationTests` (5): RED (compile) on the missing members, then RED (assertion) with the
old default (`testProcessDefaultIsNotTheRealLog`: "/Users/.../.config/gio/gio.log" equal;
`testThisProcessIsDetectedAsXCTest`, `testUnderXCTestTheDefaultIsAPerProcessTempFile` failed),
GREEN. Full `swift test`: GioCoreTests 1415, GioSessionTests 338, GioMacOSTests 48, GioMacTests
19, GioPOCTests 7 with 0 failures; GioUITests 274 with 3 failures, all from the in-flight renderer
default change (`AdvancedPresentationTests` x2, `SettingsPresentationTests` x1), not HD-08.
Real log stat (read-only) before and after the full run: 927558 bytes, mtime 12:51:18 both;
fixture counts unchanged (68/12/2). Each bundle process wrote only `gio-xctest-<pid>.log` in
`$TMPDIR`. `git diff --check` clean.

## Acceptance criteria
- Alt+H/L changes keyboard focus live; config binding on e.g. Alt+Y fires.
- Killing Gio with `kill -9` restores windows within ~1s.
- All bundles green (`swift test`, read every "Executed" line); signed build OK; docs updated.

## Applicable checks
- TDD: STRICT ON. Runner `swift test` (5 bundles).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: UNAVAILABLE (gentle-ai trailing-space path defect; user chose continue).

## Routes
- HD-01..HD-03 one delegated writer; HD-04..HD-06 one delegated writer; HD-07 one delegated writer.

## Progress
- 2026-09-29: document created. Next: HD-01..HD-03.
- 2026-09-29: HD-01..HD-03 done, pushed. Next: HD-04..HD-06.
- 2026-09-29: HD-04..HD-06 done, pushed. Next: HD-07 guardian.
- 2026-09-29: HD-07 done, pushed. All hardening tasks code-complete. Next: user live test.
- 2026-10-08: HD-08 done, committed as `ef3d9cb`: tests no longer pollute the real log.
