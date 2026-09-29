# Testing

Gio is tested at two levels: automated XCTest bundles that cover all decision logic without a display, and a manual live checklist for the behaviors that only a real macOS desktop can prove. Automated tests and a successful signed build never prove live Accessibility behavior; the feature documents in `odd/tasks/` mark such items **LIVE PENDING** until someone has run them.

Contents: [Bundles](#test-bundles) · [Running](#running-tests) · [TDD workflow](#strict-tdd-workflow) · [Signed build](#signed-build) · [Live checklist](#live-manual-test-checklist) · [Log recipes](#log-recipes) · [Limitations](#known-limitations)

## Test bundles

All tests use **XCTest** (`import XCTest`); there is no Swift Testing suite. Counts below are `func test...` methods and equal the executed counts at the time of writing.

| Bundle (target) | Tests | Covers |
| --- | --- | --- |
| `GioCoreTests` (`Tests/GioCoreTests`) | 602 | Everything in `GioCore`, using mock actuators and temp files. See the breakdown below. |
| `GioMacOSTests` (`Tests/GioMacOSTests`) | 23 | Pure parts of the adapters: AX vertical flip, keycode to combo mapping, `SystemWindow` description, own-pid guards (`isManageableProcess`, actuator refuses Gio's windows), tile assembly. |
| `GioUITests` (`Tests/GioUITests`) | 20 | View models only: bar status parsing, launcher ranking/routing/app scan, main window sections and activation policy. SwiftUI views themselves are compile-checked, not tested. |
| `GioPOCTests` (`Tests/GioPOCTests`) | 7 | `gio-poc` verb parsing (`parseCLICommand` in `Sources/GioPOC/CLICommand.swift`). |
| `GioMacTests` (`Tests/GioMacTests`) | 19 | **Legacy** prototype only (`GioMac`: AX geometry validation, space window snapshot). Not related to the running app. |

### What `GioCoreTests` covers

| Area | Test files |
| --- | --- |
| Layout and viewport | `ScrollableLayoutEngineTests`, `ViewportTests`, `RevealGeometryTests`, `CenterColumnTests`, `ColumnWidthTests`, `MaximizeColumnTests`, `ParkingPlannerTests`, `RestorePlannerTests`, `WorkspaceVisibilityTests` |
| State and navigation | `WorkspaceStateTests`, `WorkspaceManagerTests`, `DisplayManagerTests`, `FocusNavigationTests`, `WindowMoveTests`, `WindowResizeTests`, `ConsumeExpelTests`, `FullscreenTests` |
| Windows | `WindowRegistryTests`, `WindowAdmissionTests`, `WindowModeTests`, `FloatingManagementTests`, `MinimizeLifecycleTests`, `WindowReconcileDecisionTests`, `WindowRuleTests`, `ObservationBookTests`, `WindowEventPolicyTests` (event routing, echo gate, retry delays) |
| Focus | `FocusAdoptionTests`, `FocusSettleTests` |
| Reconciliation and motion | `ReconcilerTests`, `ParkedReconcileTests`, `LeanWriteTests`, `WriteLaneTests`, `ReflowTimingTests`, `AnimationTests`, `MotionPlannerTests`, `MotionPlayerTests`, `MotionWriteTests`, `WorkspaceSwitchMotionTests` |
| Hotkeys and config | `HotkeyTests`, `ShortcutCatalogTests`, `ConfigTests`, `ConfigPatcherTests`, `MotionConfigTests`, `NiriControlsConfigTests`, `ThemeTests` |
| Commands, IPC, diagnostics | `CommandDispatcherTests`, `IPCTests` (real socket round trips), `DoctorSetupTests`, `OverviewModelTests`, `LogViewModelTests`, `GioLogTests` |
| Recovery and integration | `RecoveryTests`, `GuardianTests` (pipe protocol, decision table, launch arguments), `TilingPipelineTests` (created, rules, registry, workspace, layout, reconciler, refocus, switch, recover with a mock actuator) |
| Legacy | `TileLayoutTests`, `NativeTilingCoordinatorTests`, `SpaceWindowEligibilityTests`, `GapChangeTransactionTests`, `WorkspacePreferencesTests`, `VisibleAreaDiagnosticTests`, `DisplayUsableBoundsTests` |

### Not covered by automated tests

- `SessionHost` and `main.swift` (`GioDesktop` has no test target). Its logic is deliberately thin and delegates to tested Core functions.
- Live `AXUIElement` behavior: `AXWindowActuator` I/O, `SystemWindowObserver`, `HotkeyTap` event delivery, `snapshotDisplayList`.
- SwiftUI views (`GioUI/*View.swift`) beyond compile checks.
- Multi-display behavior on real hardware.

## Running tests

```sh
swift test                                              # every bundle
swift test --filter GioCoreTests                        # one bundle
swift test --filter GioCoreTests.WriteLaneTests         # one test class
swift test --filter GioCoreTests.ViewportTests/testEnsureVisibleScrollsMinimally   # one method
swift build                                             # compile everything, including the executables
git diff --check                                        # whitespace errors in the change
```

> **Read every "Executed" line, not just the last one.** `swift test` runs each bundle as its own XCTest run and prints an `Executed N tests` line **per bundle** (plus an `All tests` line right after it). The last line printed belongs to whichever bundle ran last, so it can look green while an earlier bundle failed. A filtered run prints `Executed 0 tests` for the bundles it skipped; that is normal.

A compact way to see one verdict per bundle:

```sh
swift test 2>&1 | rg "Test Suite '.*\.xctest' (passed|failed)" -A1
```

Baseline at the time of writing, all with 0 failures:

| Bundle | Executed |
| --- | --- |
| `GioUITests` | 20 |
| `GioPOCTests` | 7 |
| `GioMacTests` | 19 |
| `GioMacOSTests` | 23 |
| `GioCoreTests` | 602 |

Two environment notes:

- `IPCTests` bind temporary Unix sockets. Earlier, a live Gio session holding the real socket made two tests fail; the suite was made daemon-agnostic, but keep the rule: **tests must never depend on, or write to, the real `~/.config/gio/` files**.
- A test count that differs from the number of `func test` declarations is worth investigating (a past mismatch of 210 executed against 247 declared was recorded in `odd/tasks/window-coverage.md`).

## Strict TDD workflow

Strict TDD is on for this repository. The runner is `swift test` (XCTest). Every behavior change follows RED, GREEN, REFACTOR:

1. **RED.** Write the smallest failing test first and watch it fail. A compile failure counts as RED when the test references a type or function that does not exist yet; record it as "RED (compile)". Prefer a failure with real expected numbers, for example the reveal-geometry tests that reproduced the live numbers before the fix.
2. **GREEN.** Write the least code that passes. Run the focused test, then the whole bundle.
3. **REFACTOR.** Clean up with tests green. Do not change behavior in this step.
4. **Close the task.** Run every bundle (`swift test`), `git diff --check`, and the signed build if adapters or the app changed. Only then check the task off and commit.

How the design supports it: put decisions in **pure logic in `GioCore`**, inject time and I/O, and make the host thin.

- Clocks are injected (`ReflowClock`, uptime parameters in `WriteEchoGate`, `FocusSettle.poll(now:)`), never read inside Core logic.
- OS access sits behind protocols with mocks in tests (`WindowActuator`, `MotionFrameSink`, `FrameAttributeIO`).
- Pure planners return plain values (`planParking`, `planMotion`, `planRestore`, `planWriteLanes`, `planDisplayLayout`) so a test asserts on data, not on windows.
- State machines take events and return commands (`FocusSettle`, `ReflowDeferral`, `ObservationBook`), and the host owns timers.
- Config edits are text-level and round-trip through the parser (`patchGioConfig`), so tests assert on strings.

Do not lower the bar by testing through the live desktop. If something can only be checked live, extract the decision so the decision is tested and the live part becomes a one-line adapter call, then add it to the live checklist.

## Signed build

Compile the real app the way Xcode does. Use your own team ID; the feature documents use the original author's (`2CAK428VHF`), which will not sign for you:

```sh
xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug \
  -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> build
```

A green signed build confirms the `Gio` target still compiles and links `GioCore`, `GioMacOS` and `GioUI`. It says nothing about live behavior.

## Live manual test checklist

Run the signed **Gio** scheme from Xcode with several windows open (a browser, a terminal, an editor, an Electron app), and keep `tail -f ~/.config/gio/gio.log` open. Record hardware, macOS version and log lines with your observations. Do not run `gio-poc tile` against a desktop you care about while Gio runs; it is a one-shot placement tool that competes with the session.

| # | Area | Steps | Expected |
| --- | --- | --- | --- |
| 1 | Window coverage | Launch Gio with 6 or more windows open. Open a new app, then a new window in a running app. Close a window. Minimize and restore one. Open a dialog. | Normal windows tile into columns. New windows join without switching apps. Closing reflows at once. Minimized windows leave the layout and return to their column. Dialogs and fixed-size windows float and show a reason in **Overview**. |
| 2 | Parking | With more columns than fit, look at the display edges. | Off-viewport windows sit at the left or right edge (1 pt visible) and never overlap the visible columns. Log shows `parked=` counts. |
| 3 | Click focus | Click windows in different columns, including ones partly visible. | The clicked window becomes focused; the strip does not jump or rewrite every window. Log shows `focus adopt ... scroll=no scroll` for fully visible columns and no `focus dropped`. Clicking must not drag or move windows under the cursor. |
| 4 | Keyboard navigation | `Alt+H/L/J/K`, `Alt+Shift+H/L/J/K`. | Focus moves between columns and within a column; the strip scrolls just enough to reveal the focused column; move rearranges windows. |
| 5 | Animations | Scroll with `Alt+L` past the edge; toggle `[animations] enabled`; set `duration-ms = 0`. | Motion is smooth at 200 ms; disabled or 0 ms is instant. Check `anim done` lines: `dropped` should be low and `frames` near duration times display rate. |
| 6 | Workspaces | `Alt+2`, `Alt+1`; `Alt+Shift+2` on a window; switch back. Also test with a floating window. | Only the active workspace's windows are visible. Switch animates vertically through the bottom edge. Floating windows return to their old frame. Moved window follows to its workspace. |
| 7 | Column controls | `Alt+R` (cycle presets), `Alt+Minus`/`Alt+Equal`, `Alt+F` twice, `Alt+C`, `Alt+[`/`Alt+]`. | Preset widths cycle; +/-10% steps clamp; maximize toggles back to the previous width without drift; center scrolls the column to the middle; consume/expel stack and unstack windows. |
| 8 | Fullscreen and floating | `Alt+Shift+F`, focus another window; `Alt+Shift+Space`. | Fullscreen fills the display under the menu bar, others park; focusing another window brings the layout back. Floating toggles the window in and out of the strip. |
| 9 | Config | Edit a value in `config.toml`, run `gio reload` (or Apply in **Layout**). Introduce a syntax error. | Valid edits apply live. An invalid file keeps defaults and shows messages in **Overview** and **Diagnostics**; the WM keeps running. |
| 10 | Desktop app | Close the main window, then reopen from the menu bar item. Check the Dock icon while the window is open. | Closing hides the window and the Dock icon; tiling continues. **Open Gio** brings it back. Only one Gio window exists (plus the summoned launcher). |
| 11 | Quit restore | Park some windows (many columns), then Quit from the menu, Cmd+Q, and separately `kill -TERM <pid>`. | All parked windows return fully on screen. Log shows `restore applied=N`. |
| 12 | Crash recovery | Stop from Xcode (SIGKILL) with parked windows, then run the `gio-poc-restore` scheme or `swift run gio-poc restore`. | Windows return on screen. |
| 12b | Guardian | With parked windows, `kill -9` the main Gio process only: `kill -9 $(ps -axo pid=,command= | rg 'MacOS/Gio' | rg -v -- '--guardian' | awk '{print $1}')` (`pgrep -x Gio` matches the guardian too, and killing both skips the restore). Then quit Gio normally on another run. | After SIGKILL the windows return on screen within about 1 s with no manual step; log shows `guardian started parent=N` at launch and `guardian restore applied=N`. A normal Quit logs `guardian clean exit` and moves nothing. |
| 13 | Own-window guard | Click Gio's main window and the launcher repeatedly. | No crash; Gio's windows are never moved or tiled. |
| 14 | Displays | Connect or disconnect a second display. | Layout refits; unplugging one display does not corrupt the other. (Multi-display is not validated live yet.) |

## Log recipes

Logs are written to `~/.config/gio/gio.log` (all levels; the file has no level filter) and shown in the **Logs** section and by `GioCLI logs [--level ...]`. Lines look like `[timestamp] [LEVEL] message`. Messages contain IDs, counts, timings and app names, never window titles.

Start with:

```sh
rg "reflow timing|anim done|focus adopt|focus dropped|restore" ~/.config/gio/gio.log
```

| Line (prefix) | Level | Meaning |
| --- | --- | --- |
| `reflow timing total=Xms windows=N axCalls=M slowest=<app> Yms focus=Zms` | info | One reconcile pass: total time, windows written, Accessibility calls, slowest app. Healthy passes measured live were 2 to 12 ms. |
| `reflow slow window=pid:id app=<name> Yms axCalls=N` | debug | A window write that took more than 20 ms. Names the slow app. |
| `reflow applied=A parked=P already=Q failed=F` | info | Outcome counts. `applied` = moved, `parked` = written to a parking spot, `already` = already correct (nothing written), `failed` = write failed or timed out. |
| `reconcile applied=... parked=... already=... vanished=... failed=...` | debug | Same, from the reconciler, plus windows that no longer exist. |
| `reconcile failure id=P:E app=<name> kind=<kind> requested=(x,y,w,h) actual=(x,y,w,h)` | warn, then debug | One failed window write. `kind` is `frameMismatch`, `writeFailed(<attr>,<AXError>)`, `readbackFailed(...)`, `timeout`, `other` and so on. Warned once per window and kind per session, debug on repeats. Ids and app names only, never titles. |
| `parked clamped id=pid:id` | debug | macOS clamped a parked position; the landing was accepted because it still counts as parked. |
| `anim done windows=N frames=F dropped=D duration=Xms slowest=<app> Yms` | info | One finished animation. `frames` = sampled display ticks, `dropped` = per-app frames skipped because that app was still writing. Live pass: 25 frames per 200 ms, `dropped` usually 0. |
| `focus adopt source=<activation\|focusChanged\|rescan> id=pid:id column=N <visible\|parked\|unplaced> changed=<bool> scroll=<a->b\|no scroll>` | debug | Focus was adopted from the OS. `scroll=no scroll` on a visible column is healthy; a large scroll after a click on a visible column points to a reveal or geometry bug. |
| `focus dropped source=... id=... frame=... click=x,y reason=focused window not under click` | debug | An adoption was rejected because the focused window was not under the click after one re-read. |
| `restore applied=N vanished=N failed=N` | info | A restore pass on quit, on startup, or from **Restore All Windows**. |
| `restore-all requested from the app moved=N` | info | Diagnostics button used. |
| `hotkey <action>` | debug | A bound hotkey reached the session. If a shortcut does nothing and this line is absent, the tap did not see it. |
| `discovery exclude pid=N app=<name> <label>` | info | A window was excluded (`ignore(...)`) with its reason. |
| `discovery skipped=N windows with unreadable attributes` | debug | Windows whose attributes could not be read. |
| `hotkey tap refused; running without global hotkeys` | warn | Accessibility permission missing or tap creation failed. |
| `observation refused for ... app(s)` | warn | An app refused an AX observer; it is retried when it activates or relaunches. |
| `guardian started parent=N`, `guardian clean exit`, `guardian restore applied=N ...` | info | Guardian process markers; restore only after an abrupt Gio death. |
| `config reloaded from the app`, `config edited from the app and reloaded`, `session started`, `ipc serving <path>` | info | Lifecycle markers. |

Handy filters:

```sh
rg "\] \[(WARN|ERROR)\]" ~/.config/gio/gio.log          # only problems
rg "reflow slow window" ~/.config/gio/gio.log            # who is slow
rg "anim done" ~/.config/gio/gio.log | tail -20          # recent animation quality
```

## Known limitations

Documented, not bugs to chase blindly:

- **macOS will not place a window fully off-screen.** That is why parked windows keep a 1 pt sliver and the reconciler accepts clamped landings (up to 40 pt visible).
- **SIGKILL and crashes cannot run Gio's own restore.** The guardian process restores the windows instead (it needs Accessibility, same signed app). Power loss, or a guardian that failed to start, still needs `gio-poc restore` or restarting Gio.
- **Accessibility speed depends on the app.** Each AX call is a cross-process request the target answers on its own schedule. One live sample saw a Slack write reach 250 ms (the lane timeout) while typical writes were a few ms. A hung app is abandoned after 0.25 s and skipped until it recovers.
- **Other macOS Spaces.** Gio manages windows Accessibility reports for the current context; windows on other Spaces are not laid out. There is no Space switching support.
- **Native fullscreen** windows are treated as `suspend` candidates and left alone. Gio's own fullscreen is a layout mode, not a Space.
- **Multi-display:** the AX vertical flip uses a single display height (`NSScreen.main`), and the workspace-switch animation is carried by the first display. Not validated live on multiple displays.
- **Window rules match the app name only** (exact string), and only when a window first appears. Editing a rule from the app drops comments inside that rule block.
- **Config bindings are additive and limited to the tap's key table.** See [USER_GUIDE](USER_GUIDE.md#custom-key-bindings).
- **Parsed but not yet consumed:** themes. They are validated and stored, and they have no effect on the running session today.
- **`gio restart`** needs a live session: with no daemon there is nothing to restart. Under `swift run` the relaunched executable is a child process of the old one.
- **Session-driven focus:** keyboard and IPC focus/move/workspace actions carry a `FocusIntent` that the final reflow pass hands to the reconciler (pure logic is tested in `FocusIntentTests`); the AX focus and raise itself is verified live only. Check that `Alt+H/L/J/K` moves typing focus on your setup.
- **App-level UI is compile-checked only** and several live behaviors are marked LIVE PENDING in `odd/tasks/`.
