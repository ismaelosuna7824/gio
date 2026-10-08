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
- Logging is isolated automatically (HD-08): under XCTest the global `GioLog` defaults to a per-process temp file, `$TMPDIR/gio-xctest-<pid>.log`, instead of `~/.config/gio/gio.log`, so a suite that never sets `GioLog.logFilePath` cannot leak fixture lines (such as `app=pid30`) into the log users send for analysis. Suites that assert on file contents still set their own temp path (`GioLogTests`, `LogSinkTests`).
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

Compile the real app the way Xcode does. Signing comes from `Config/Signing.xcconfig`, plus your git-ignored `Config/Signing.local.xcconfig` when it exists (see the README). No `DEVELOPMENT_TEAM` argument is needed; without the local file the build is ad-hoc signed:

```sh
xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug \
  -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' build
```

A command-line `DEVELOPMENT_TEAM=<TEAM_ID>` argument still overrides the xcconfig files.

A green signed build confirms the `Gio` target still compiles and links `GioCore`, `GioMacOS` and `GioUI`. It says nothing about live behavior.

## Live manual test checklist

Run the signed **Gio** scheme from Xcode with several windows open (a browser, a terminal, an editor, an Electron app), and keep `tail -f ~/.config/gio/gio.log` open. Record hardware, macOS version and log lines with your observations. Do not run `gio-poc tile` against a desktop you care about while Gio runs; it is a one-shot placement tool that competes with the session.

| # | Area | Steps | Expected |
| --- | --- | --- | --- |
| 1 | Window coverage | Launch Gio with 6 or more windows open. Open a new app, then a new window in a running app. Close a window. Minimize and restore one. Open a dialog. | Normal windows tile into columns. New windows join without switching apps. Closing reflows at once. Minimized windows leave the layout and return to their column. Dialogs and fixed-size windows float and show a reason in **Overview**. |
| 2 | Parking | With more columns than fit, look at the display edges. | Off-viewport windows sit at the left or right edge (1 pt visible) and never overlap the visible columns. Log shows `parked=` counts. |
| 3 | Click focus | Click windows in different columns, including ones partly visible. | The clicked window becomes focused; the strip does not jump or rewrite every window. Log shows `focus adopt ... scroll=no scroll` for fully visible columns and no `focus dropped`. Clicking must not drag or move windows under the cursor. |
| 4 | Keyboard navigation | `Alt+H/L/J/K`, `Alt+Shift+H/L/J/K`. | Focus moves between columns and within a column; the strip scrolls just enough to reveal the focused column; `Alt+Shift+H/L` swap whole columns (no stacking, no-op at the edge), `Alt+Shift+J/K` reorder inside a column; typing goes to the target window at once, also while pressing keys rapidly. |
| 5 | Animations | Scroll with `Alt+L` past the edge; toggle `[animations] enabled`; set `duration-ms = 0`. | Motion is smooth at 200 ms; disabled or 0 ms is instant. Check `anim done` lines (they end with `curve=spring` or `curve=ease-out`): `dropped` should be low and `frames` near duration times display rate. With the default spring, press `Alt+L`/`Alt+H` rapidly: the motion flows without restarting, `duration` stays well below the sum of the presses, and no press is ignored. In a stacked column (for example two windows sharing a column) that changes heights, and for neighbouring columns that change widths, the previous composition must not overlap the new one mid-motion: shrinking windows resize at the first frame, growing ones at the end. |
| 6 | Workspaces | With windows open: `Alt+Shift+U` (window goes to a new workspace below and you follow it), `Alt+I` back up, `Alt+U` down; `Alt+Shift+I` to bring it back (the emptied workspace disappears). `Alt+9` lands on the empty bottom workspace; leave it and it is removed. Check the menu bar list and **Overview** stack line. `Alt+2`, `Alt+1`; `Alt+Shift+2` on a window; switch back. Also test with a floating window. | Only the active workspace's windows are visible. Switch animates vertically through the bottom edge. Floating windows return to their old frame. Moved window follows to its workspace. Stack is dynamic: exactly one empty workspace stays at the bottom, an emptied workspace disappears once left (indices below shift up), nothing hidden is lost, and quitting Gio restores every hidden window. The switch always animates through the bottom edge, up or down. |
| 7 | Column controls | `Alt+R` (cycle presets), `Alt+Minus`/`Alt+Equal`, `Alt+F` twice, `Alt+C`, `Alt+[`/`Alt+]`. | Preset widths cycle; +/-10% steps clamp; maximize toggles back to the previous width without drift; center scrolls the column to the middle; consume/expel stack and unstack windows. |
| 8 | Fullscreen and floating | `Alt+Shift+F`, focus another window; `Alt+Shift+Space`. | Fullscreen fills the display under the menu bar, others park. Focusing another window (`Alt+H/L`, click) scrolls to that window as usual while the fullscreen window keeps its mode and its full size (it is never resized, only moved or parked off-screen); focusing the fullscreen window again fills the display again; `Alt+Shift+F` on it restores its column; closing or minimizing it also ends fullscreen. Floating toggles the window in and out of the strip. |
| 9 | Config | Edit a value in `config.toml`, run `gio reload` (or Apply in **Layout**). Introduce a syntax error. | Valid edits apply live. An invalid file keeps defaults and shows messages in **Overview** and **Diagnostics**; the WM keeps running. |
| 10 | Desktop app | Close the main window, then reopen from the menu bar item. Check the Dock icon while the window is open. | Closing hides the window and the Dock icon; tiling continues. **Open Gio** brings it back. Only one Gio window exists (plus the summoned launcher). |
| 11 | Quit restore | Park some windows (many columns), then Quit from the menu, Cmd+Q, and separately `kill -TERM <pid>`. | All parked windows return fully on screen. Log shows `restore applied=N`. |
| 12 | Crash recovery | Stop from Xcode (SIGKILL) with parked windows, then run the `gio-poc-restore` scheme or `swift run gio-poc restore`. | Windows return on screen. |
| 12b | Guardian | With parked windows, `kill -9` the main Gio process only: `kill -9 $(ps -axo pid=,command= | rg 'MacOS/Gio' | rg -v -- '--guardian' | awk '{print $1}')` (`pgrep -x Gio` matches the guardian too, and killing both skips the restore). Then quit Gio normally on another run. | After SIGKILL the windows return on screen within about 1 s with no manual step; log shows `guardian started parent=N` at launch and `guardian restore applied=N`. A normal Quit logs `guardian clean exit` and moves nothing. |
| 13 | Own-window guard | Click Gio's main window and the launcher repeatedly. | No crash; Gio's windows are never moved or tiled. |
| 13b | Open at Login | From the signed app (ideally a copy in `/Applications`): Overview > Status, turn **Open at Login** on; check System Settings > General > Login Items; log out and back in (or restart). Then turn it off in System Settings and return to Overview; finally turn it off from Gio. Repeat the login once with Accessibility revoked. | The switch turns on (if macOS asks for approval the row says so and **Open Login Items…** opens the right pane); Gio appears in Login Items. After login Gio runs from the menu bar with no main window, and tiles; log: `login item set enabled=true status=enabled`, then `launch atLogin=true window=hidden`. A change made in System Settings shows in Overview within 3 s. Without Accessibility the window opens at login (`window=shown`). |
| 14 | Displays | Connect or disconnect a second display; start Gio with windows already on both displays; arrange the second display left of the laptop in System Settings and restart Gio; switch workspaces on each display (click a window there first, then `Alt+U`/`Alt+I`); click a window on the other display. Then arrange the second display above the laptop and switch workspaces on the upper display. | Layout refits; unplugging one display does not corrupt the other. Each startup window stays on the display it was on. Hidden windows park below their own display (never on the other one) and the switch slides on the display that switched. Default-width columns are half of their own display. Clicking a window on the other display moves focus there without a workspace-switch slide. With displays of different heights, windows land at the right height on both (AX flip uses the primary display). With the display above, its switch does not slide (windows appear and disappear at the end of the switch) and no window of the upper display ever shows on the laptop; its hidden windows hang off its bottom corner or its side (MM-03). The laptop below still slides. (MM-01, MM-03, live pending.) |
| 14b | Monitor actions | Two displays side by side (and, if possible, one above). Windows on the left display, the right one showing an empty workspace. `Ctrl+Alt+L`, type, `Ctrl+Alt+H`; `Ctrl+Alt+Shift+L` on a stacked column, then `Ctrl+Alt+Shift+H` back; bind `move-window-to-monitor-right` and `move-workspace-to-monitor-right` in `[keybindings]` and press them; press each at the edge with no display there. Toggle a window floating (`Alt+Shift+Space`) and press `Ctrl+Alt+Shift+L` on it, then switch workspaces on each display. Repeat with `mouse-follows-focus = false`. | `Ctrl+Alt+L` focuses the right display: with mouse-follows-focus the cursor jumps to its middle (no window there), keyboard focus stays on the previous window; `Ctrl+Alt+H` returns focus and the cursor to the focused window. The column moves with all its windows and its width, lands next to the right display's focused column, keeps focus and the left display shows the column that took its place. The window move takes only the focused window; the workspace move shows the whole workspace on the right and the left display its next workspace. At an edge nothing changes. A floating window moves onto the right display, same size, same offset from the bottom-left corner of the usable area, kept inside it (MM-03); afterwards it hides and returns with the right display's workspace, not the left one's. Logs: `hotkey focusMonitor(...)` and no title. **Not verified by automated tests.** |
| 15b | Snapshot renderer | Grant Screen Recording (Overview, then relaunch), leave `[animations] renderer = "snapshot"`, log level `info`. Settle, wait a second, then `Alt+L`/`Alt+H` past the edge, `Alt+F` (maximize), `Alt+U`/`Alt+I` (workspace switch), and press keys rapidly. Also revoke the permission in System Settings and repeat. | Scrolling looks fluid at display refresh with the window contents as of the last settle; the ring disappears during the flight and returns at the end; rapid keys retarget without a jump. Logs: `snapshot flight layers=N cacheAgeMs=M duration=Xms` and `anim done ... renderer=snapshot`. The first motion after launch or after an idle minute may log `snapshot fallback reason=cache-miss` and use `renderer=ax`. Clicking during a flight removes the overlay immediately (`snapshot flight aborted reason=mouse-down`). With the permission revoked motions log `renderer=ax` and no overlay is ever shown. Confirm no overlay stays on screen after any of these. **Not verified by automated tests.** |
| 15 | Focus ring | With several windows, press `Alt+H/L/J/K`, click windows, run `Alt+Shift+F` on one, minimize one, switch workspaces (`Alt+2`, `Alt+1`), open Gio's main window and then click another app. Set `[focus-ring] width = 8` and `active-color = "#ff5555"`, then `enabled = false`, using `gio reload` or **Layout**. | A colored rounded outline hugs the focused window and slides with it during scroll animations without lag or blocked hotkeys. It hides for fullscreen, minimized and parked focus, while Gio's own window is active, and returns when another app is focused. It never steals focus, is not clickable, and is absent from Cmd+Tab. Config changes apply live. Log (debug) shows `focus ring shown/hidden` only on transitions. |
| 15c | Focus dim | Default config (`[focus] indicator = "dim"`), several tiled columns plus a floating window and another app's window overlapping a tiled one. Press `Alt+H/L`, click windows, switch workspaces, drag a window by its title bar and release, maximize one (`Alt+F`), then set `dim-strength = 0.4`, `indicator = "ring"` and `"none"` with `gio reload` or **Layout**. Toggle Reduce Motion (Accessibility, Display). | At rest the unfocused tiled windows are slightly darker and the focused one is lit; the floating window, the overlapping app window and menus are never darkened. The dim fades out as soon as a scroll or switch starts, is never visible mid-motion or during a drag, and fades back once the final pass and any native zoom settled. Clicks go through it; it never steals focus and is absent from Cmd+Tab. `ring` shows only the ring, `none` shows nothing. With Reduce Motion there is no fade. Log (debug): `focus dim shown regions=N` / `focus dim hidden reason=motion|drag|zoom|...` only on transitions. |
| 15d | Other Spaces | With several tiled windows and a second Desktop (Control+Right). Switch to the other Desktop, open or activate apps there (Finder, a new window), wait a few seconds, then return with Control+Left. Repeat with a native fullscreen app. Log level `info`. | Nothing on the managed Desktop moves while you are away, and the windows of the other Desktop are never registered or laid out by Gio. Back on the managed Desktop every window is exactly where it was, with at most one re-placement pass. Logs: `space foreign; pausing layout` on leaving and `space managed; reflow` on returning. Other Desktops are still not tiled. **Not verified by automated tests** (Spaces need a real desktop). |
| 15e | OS focus reveal | Two windows of the same app (for example Chrome) on different Gio workspaces, with the second one hidden. Press Control+Down (App Exposé), pick the hidden one. Repeat with Mission Control and a Dock click. Log level `info`. | Gio switches to the workspace of the window you picked and shows it, scrolled into view; the window you picked keeps keyboard focus (Gio issues no focus call of its own). A window on the current workspace still scrolls into view as before. Log: `focus reveal id=<pid>:<id> workspace=<n> source=focusChanged|activation`. **Not verified by automated tests** (App Exposé needs a real desktop). |
| 15f | Screen Recording relaunch | Reset onboarding (`defaults delete <bundle id> GioOnboardingCompleted`), revoke Screen Recording for Gio, launch, and reach the Screen Recording step. Click **Open System Settings**, grant it, return. Click **Relaunch Gio**. Repeat once more from Overview > **Request Access…** with onboarding already completed. | Before the click the step shows a neutral "Not granted" line with no spinner; after it, the "Granted it?" message and a prominent **Relaunch Gio** button replace it. Relaunch restarts through the normal restart path (no second instance, windows restored then re-tiled) and onboarding reopens on the Screen Recording step showing "Screen Recording is on." Closing with **Set Up Later** or finishing clears the marker. From Overview with onboarding completed, onboarding does not reopen. **Not verified by automated tests.** |

## Checking idle behavior

Gio at rest should cost ~0%. With the main window closed to the menu bar and no window activity for a minute:

1. Activity Monitor, **Energy** tab: Gio's Energy Impact should be ~0 and "Idle Wake Ups" near zero (only the 30 s tap watchdog).
2. `tail -f ~/.config/gio/gio.log` (or `level = "debug"` for more detail): no lines should appear while idle. A steady stream means something is polling.
3. Open the main window: the visible section refreshes every 1-3 s; close it again and confirm the wakeups stop.
4. Click the menu bar item: workspace rows are current without any background polling.

## Log recipes

Logs are written to `~/.config/gio/gio.log` (minimum level from `[logging] level`, default `info`; batched writes, rotated at about 1 MB to `gio.log.1`) and shown in the **Logs** section and by `GioCLI logs [--level ...]`. Set `level = "debug"` and `gio reload` to see per-event `reflow timing`, `focus adopt`, `hotkey` and `reconcile` lines. Lines look like `[timestamp] [LEVEL] message`. Messages contain IDs, counts, timings and app names, never window titles.

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
| `min size learned id=P:E app=<name> w=W h=H` | info | A write landed larger than requested and the growth was not position clamping (FI-02). The window's minimum is remembered for the session (0 = no evidence in that dimension) and one relayout follows. Once per growth, so it stops after the first pass; `failed=` should be 0 on the next reflow. |
| `render mismatch id=P:E app=<name> ax=(x,y,w,h) ws=(x,y,w,h)` | warn, then debug | About 150 ms after a settle, the WindowServer draws a window that should be on screen more than 2 pt away from where Accessibility says it is (`ws` vs `ax`, Cocoa coordinates). This is the "empty area until the next hotkey" symptom (FI-05). Warned once per window per session. |
| `render nudge id=P:E app=<name> fixed=<bool>` | info if fixed, warn if not | Result of the one corrective nudge (offset write then target write) after a mismatch, re-checked 100 ms later. `fixed=false` means the app still draws the window elsewhere; there is no second attempt in that settle. |
| `parked clamped id=pid:id` | debug | macOS clamped a parked position; the landing was accepted because it still counts as parked. |
| `snapshot flight layers=N cacheAgeMs=M duration=Xms` | info | One overlay flight that settled: layers drawn, age of the oldest image used, time from start to settle. |
| `snapshot fallback reason=<cache-miss\|no-backdrop\|nothing-visible> ids=N` | info | The motion used the AX renderer because N visible windows had no fresh image (or no wallpaper backdrop was ready). A capture is scheduled. |
| `snapshot flight aborted reason=<watchdog\|mouse-down\|display-change>` | warn for watchdog, else info | The overlay was removed early. Repeated `watchdog` lines are a bug to report. |
| `snapshot cache entries=N pixels=P evicted=E` | debug | Pre-capture finished; images kept and evicted (LRU / memory cap). |
| `render mismatch ... ws=missing` | warn, then debug | A visible window had no on-screen WindowServer entry (not drawn); it is nudged once. |
| `anim done windows=N frames=F dropped=D duration=Xms slowest=<app> Yms` | info | One finished animation. `frames` = sampled display ticks, `dropped` = per-app frames skipped because that app was still writing. Live pass: 25 frames per 200 ms, `dropped` usually 0. |
| `focus adopt source=<activation\|focusChanged\|rescan> id=pid:id column=N <visible\|parked\|unplaced> changed=<bool> scroll=<a->b\|no scroll>` | debug | Focus was adopted from the OS. `scroll=no scroll` on a visible column is healthy; a large scroll after a click on a visible column points to a reveal or geometry bug. |
| `focus dropped source=... id=... frame=... click=x,y reason=focused window not under click` | debug | An adoption was rejected because the focused window was not under the click after one re-read. |
| `restore applied=N vanished=N failed=N` | info | A restore pass on quit, on startup, or from **Restore All Windows**. |
| `restore-all requested from the app moved=N` | info | Diagnostics button used. |
| `hotkey <action>` | debug | A bound hotkey reached the session. If a shortcut does nothing and this line is absent, the tap did not see it. |
| `discovery exclude pid=N app=<name> <label>` | info | A window was excluded (`ignore(...)`) with its reason. |
| `discovery skipped=N windows with unreadable attributes` | debug | Windows whose attributes could not be read. |
| `hotkey tap refused; running without global hotkeys` | warn | Accessibility permission missing or tap creation failed. |
| `hotkey tap re-enabled after <timeout\|userInput\|watchdog> (count=N)` | warn first, then debug | macOS disabled the event tap (slow main thread) and Gio switched it back on. Frequent lines mean something keeps blocking the main thread. |
| `hotkey tap restarted mouse-moved=<bool>` | info | A config reload changed `focus-follows-mouse`, so the tap was rebuilt with or without pointer moves. |
| `observation refused for ... app(s)` | warn | An app refused an AX observer; it is retried when it activates or relaunches. |
| `guardian started parent=N`, `guardian clean exit`, `guardian restore applied=N ...` | info | Guardian process markers; restore only after an abrupt Gio death. |
| `config reloaded from the app`, `config edited from the app and reloaded`, `session started`, `ipc serving <path>` | info | Lifecycle markers. |

Handy filters:

```sh
rg "\] \[(WARN|ERROR)\]" ~/.config/gio/gio.log          # only problems
rg "reflow slow window" ~/.config/gio/gio.log            # who is slow
rg "anim done" ~/.config/gio/gio.log | tail -20          # recent animation quality
```

### Launcher and window-open timing

Log timestamps have one-second resolution, so latency is carried inside the lines, in milliseconds (all `info`, ids and app names only):

| Line (prefix) | Meaning |
| --- | --- |
| `launcher summon→shown ms=N source=<hotkey\|menu> apps=N cached=<bool>` | From the Alt+Space hotkey firing to the panel ordered front and key. Healthy: tens of ms. The app list comes from the background cache, never a scan. |
| `launcher appsReady ms=N apps=N icons=N reason=<startup\|refresh>` | One background scan of the Applications folders plus icon drawing (off the main thread). `startup` runs at launch; `refresh` after an app launch (debounced 0.5 s) or a summon that found the list older than 2 minutes. |
| `window register retry pid=N attempt=N reason=<frameUnreadable\|unclassified> delay ms=N` | A new window could not be classified yet. An unreadable frame retries at 30, 80, 200, 500 ms; anything else at 100, 300, 800 ms. `window register gave up ...` ends the retries. `pid` is the pid of the app whose AX observer delivered the created event. A pid that is not a running app (or Gio's own) is never retried: one `window register dropped pid=N reason=notRunning attempts=N` line at debug level. Unit tests log to an injected sink (`DiscoveryService.Context.log` has no default), so fixture pids such as `pid=7` must never appear in the real log. |
| `window register skipped pid=N reason=recentlyAbandoned` | Debug. PF-B: the same AX element already gave up within the last 30 s (`WindowRegistrationRetry.abandonCooldown`), so it is not classified again. Focus adoption re-offers an unreadable focused element on every activation (live: one Chrome element, 177 retry lines in 16 min; Finder's desktop). A window that becomes readable later registers through its created event or after the cooldown. |
| `window register dropped pid=N reason=<gone\|rejected> attempts=1` | Debug. PF-E: the element was destroyed before it could be read (`gone`), or its role/subrole say it is not a window to manage (a tooltip, menu, popover or sheet: `rejected`). Neither is retried, and the element joins the 30 s cooldown. Only a missing frame or role (`frameUnreadable`, `unclassified`) still gets a retry round. Live before the fix: one Chrome session produced 1730 retry/give-up lines in 76 min. |
| `settle deferred windows=N apps=N` / `settle deferred timeout apps=N ms=N` | PF-A. The final pass left out windows whose app was still writing a motion frame after 100 ms (`ReconcileReport.deferred`) instead of holding the session queue; one more final pass runs when the app is idle (debug line), or at 600 ms anyway (info line). Many timeouts for one app mean its Accessibility writes are slow (see `anim done slowest=`). |
| `window follow deferred id=P:E reason=<launched\|activated>` | A `follow = "when-active"` arrival took you to its named workspace although its app was not frontmost when the window appeared: `launched` (the app launched within 3 s), `activated` (the app became active within 1.5 s after the window was placed). A pending follow the user overrode (workspace or focus changed meanwhile) logs `window follow cancelled ... reason=userMoved` at debug level. |
| `window open id=P:E app=<name> createdEvent→registered ms=A queueWait ms=Q classify ms=K registered→firstWrite ms=B →settled ms=C total ms=D workspace=<name\|index> follow=<bool> retries=N waitedForMotion ms=W` | One line per opened window. `A`: from the moment the created event reached Gio's main thread until the window was registered. It splits into `Q` (the event waited for the session queue, which was busy with something else: a settle pass writing frames, or a switch pass waiting up to 300 ms for a motion's lane writes), `K` (Accessibility reads and admission classification, summed over every attempt; slow apps answer their first AX reads slowly), the retry delays (`retries=N`, see the retry line) and a few ms of bookkeeping (handles, per-window observer). A window registered by focus adoption instead of a created event reports `Q=0`. `B`: until the first pass wrote anything (pre-position, motion start or instant write). `C`: until the settle pass put windows on their final frames (the animation length when animated). `W`: time that pass waited for an in-flight motion's lane writes; entries never wait, so it is non-zero only when switch pre-positions had to. |

Reading them: a slow launcher with a small `summon→shown` is the appear animation, not work; a large one while `appsReady` has not logged yet means the first summon came before the startup scan landed (the list fills in when it does). For a window routed to another workspace, `follow=true` means the workspace switch brought it in (no separate entry motion), so `→settled` should be about one switch animation.

```sh
rg "launcher (summon→shown|appsReady)|window (open|register)" ~/.config/gio/gio.log | tail -20
```

## Known limitations

Documented, not bugs to chase blindly:

- **macOS will not place a window fully off-screen.** That is why parked windows keep a 1 pt sliver and the reconciler accepts clamped landings (up to 40 pt visible).
- **Mission Control (Control+Up) shows tiny windows.** It lays out every window of the Space from its real frame, including the ones Gio parks off-screen (other columns at the side edges, hidden workspaces at the bottom corner), and shrinks everything to fit them. Gio cannot change Mission Control's layout (no public API). Workaround: turn on **System Settings > Desktop & Dock > Group windows by application** (`defaults write com.apple.dock expose-group-apps -bool true && killall Dock`), the same fix AeroSpace documents. Gio's own overview (`toggle-overview`) shows the workspaces as they are.
- **SIGKILL and crashes cannot run Gio's own restore.** The guardian process restores the windows instead (it needs Accessibility, same signed app). Power loss, or a guardian that failed to start, still needs `gio-poc restore` or restarting Gio.
- **Accessibility speed depends on the app.** Each AX call is a cross-process request the target answers on its own schedule. One live sample saw a Slack write reach 250 ms (the lane timeout) while typical writes were a few ms. A hung app is abandoned after 0.25 s and skipped until it recovers.
- **Other macOS Spaces.** Gio tiles only the Space it started on. While another Space is active it adopts no focus, registers no windows, runs no rescan and writes no frames; returning triggers one reflow that re-places the managed windows. Windows on other Spaces are never laid out, and Gio does not move windows between Spaces. The managed Space is detected with a 1 pt transparent marker window (`ManagedSpaceMonitor`) read when `activeSpaceDidChangeNotification` fires; an app activation delivered before that notification can still be adopted once.
- **Native fullscreen** windows are treated as `suspend` candidates and left alone. Gio's own fullscreen is a layout mode, not a Space.
- **Multi-display (MM-01, MM-02, MM-03, live pending):** the AX/WindowServer flip uses the primary display (Cocoa origin), displays are ordered by position, startup windows stay on their display, hidden workspaces park off their own display and never on another one, each display animates its own workspace switch (a display with another display below it does not slide: its switch jumps at the end) and default-width columns resolve per display; monitor actions (`focus-monitor-*`, `move-column-to-monitor-*`, `move-window-to-monitor-*`, `move-workspace-to-monitor-*`) move focus, columns, windows and workspaces between displays, floating windows included (they keep their size and relative position, clamped inside the target). Not validated live on multiple displays yet. `focus-monitor-*` onto a display that shows no window leaves keyboard focus on the previous window (only the cursor follows, with `mouse-follows-focus`). When every side of a display touches another display, its hidden windows hang off the outer bottom-right corner of all displays, where macOS may clamp them (not seen live). Not covered: managed-Space detection still uses a marker on the primary display, so with "Displays have separate Spaces" a Space change on a secondary display is not seen; the overview shows the focused display's stack only.
- **Window rules match the app name only** (exact string), and only when a window first appears. Editing a rule from the app drops comments inside that rule block.
- **Config bindings are additive and limited to the tap's key table.** See [USER_GUIDE](USER_GUIDE.md#custom-key-bindings).
- **Parsed but not yet consumed:** themes. They are validated and stored, and they have no effect on the running session today.
- **`gio restart`** needs a live session: with no daemon there is nothing to restart. Under `swift run` the relaunched executable is a child process of the old one.
- **Session-driven focus:** keyboard and IPC focus/move/workspace actions carry a `FocusIntent` that the final reflow pass hands to the reconciler (pure logic is tested in `FocusIntentTests`); the AX focus and raise itself is verified live only. Check that `Alt+H/L/J/K` moves typing focus on your setup.
- **App-level UI is compile-checked only** and several live behaviors are marked LIVE PENDING in `odd/tasks/`.
