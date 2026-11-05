# SketchyBar integration (2026-11-05)

## Objective
Show Gio's workspaces in SketchyBar the way AeroSpace and yabai do: Gio runs a command
when the workspace state changes, bar scripts read the workspaces from the `gio` CLI as
JSON and switch with `gio workspace N`, and the layout leaves room for the bar.

## Why
User request 2026-11-05 ("podemos usar sketchybar en combinación con gio ... usar los
workspaces de gio?"); the four pieces below were approved by the user.

## Scope
Branch `dev`. SB-01 with sub-items SB-01a..SB-01e. Not pushed.

## Decisions
- **Hooks never run on the session queue.** `BarHookNotifier` (GioSession, session queue)
  diffs a small pure snapshot (`WorkspaceBarState`, `diffWorkspaceBar` in
  `GioCore/Bar/WorkspaceBarState.swift`) after every reflow (`performReflow`'s `defer`)
  and every IPC command (`IPCRouter.publishBar`), only while a hook is set (no state is
  built otherwise). The runner seam `HookRunner` and the live `ShellHookRunner` live in
  `GioMacOS/System/HookRunner.swift`: `/bin/sh -c` spawned from its own utility queue,
  stdin/stdout/stderr on /dev/null, SIGTERM at 5 s and SIGKILL 1 s later; the result hops
  back onto the session queue (`scheduler.async`) before any state is touched.
- **Coalescing:** `HookFlight` (Core) keeps at most one run in flight per hook; changes
  during a run fold into one rerun that reads the latest state when it starts.
  `on-workspace-change` runs at once; `on-windows-change` waits 100 ms
  (`BarHookNotifier.windowsDelay`), so a burst of window events runs it once.
- **What fires which hook:** workspace = focused display number, focused position or name,
  or any display's shown workspace changed; windows = any workspace's display, position,
  name, icon, color, window count or apps changed (also the stack shape). The first
  snapshot (start, or a reload that turns hooks on) fires both.
- **Environment:** the app's environment plus `GIO_FOCUSED_WORKSPACE` (position on the
  focused display), `GIO_FOCUSED_WORKSPACE_NAME` (empty for dynamic), `GIO_PREV_WORKSPACE`
  (the focused position before the last focus change, empty at first) and `GIO_DISPLAY`
  (the `[[workspace]] display` number, `WorkspaceManager.displayNumber(of:)`). An app
  opened from Finder has a bare PATH, so `~/.local/bin`, `/opt/homebrew/bin` and
  `/usr/local/bin` are prepended when missing (`hookEnvironment`).
- **Log:** `hook ran name=<hook> ms=<n> status=<code|timeout|launch-failed>`, debug for
  exit 0 and warn otherwise (a hook can run on every workspace switch; info would flood
  the 1 MB log). Never the command, never titles.
- **Config:** `[hooks]` keys are strings; a non-string is an error (like other tables), an
  empty string is off, unknown keys warn. Template: `[hooks]` with both keys commented out.
  No Settings UI.
- **JSON:** `encodeWorkspaceBarJSON` uses `JSONEncoder` with `.sortedKeys` (stable order),
  `name`/`icon`/`color` encode `null` explicitly. `windows` counts every registered window
  in the workspace's columns (floating and minimized too); `apps` are unique app names in
  column order. Main display's stack first. New `CLICommand.listWorkspacesJSON`
  (`list-workspaces --json`; any other argument is a usage error).
- **CLI in the app:** the body of `GioCLI/main.swift` moved to `runGioCLI(arguments:)`
  (GioCore/Commands/CLIClient.swift, output closures for tests); `GioCLI` is one call.
  `main.swift` checks `isGioCLIInvocation` (basename of argv[0] is exactly `gio`,
  case-sensitive, so `Contents/MacOS/Gio` stays the app) before the guardian check and
  any `NSApplication` setup. Diagnostics > Command Line > **Install Command Line Tool**
  links `~/.local/bin/gio` to `Bundle.main.executablePath` (`cliToolTarget`: only from an
  `.app` bundle). `planCLIToolInstall` (pure) creates the link (and `~/.local/bin`),
  replaces an older Gio link (into a `Gio.app`, or the FI-09 link to a built `GioCLI`),
  refuses a regular file or another program's link (Homebrew glib ships its own `gio`);
  writes go through `CLIToolFileSystem` (fake in tests, `LiveCLIToolFileSystem` live).
  The FI-09 plan that linked a source-checkout `GioCLI` (`planGioCommandInstall`,
  `gioSourceRoot`) was removed. An in-place update keeps the bundle path, so the link
  follows the app.
- **Reserved top:** `[layout] reserved-top` (0-200 pt, clamped with a warning; a
  non-number is an error). Applied where the host stores the visible frames:
  `SessionHost` keeps `systemVisibleFrames` (macOS `visibleFrame`) and derives
  `visibleFrames` with `usableFrame(visible:reservedTop:)` (Cocoa: `maxY` moves down; at
  most half the height) on display connect and on every config change
  (`invalidateConfigCaches` → `refreshUsableFrames`). Every consumer (reflow planner,
  dwindle, maximize, fill-empty-space, actions, IPC dwindle geometry, overlays) reads
  `visibleFrames`, so all respect it. Fullscreen covers the band again:
  `LayoutConfig.reservedTop` and `fullscreenFrame(display:usable:gap:reservedTop:)` add it
  back to the usable top (still clamped to the display). Settings > Layout > **Custom Bar**
  slider "Space for a custom bar (top)".

## Tasks
- [x] SB-01 (`1b54b7f`) — SketchyBar integration.
  - SB-01a `[hooks]` + `BarHookNotifier` + `ShellHookRunner`.
  - SB-01b `gio list-workspaces --json`.
  - SB-01c the app binary as the `gio` CLI; Install Command Line Tool.
  - SB-01d `[layout] reserved-top` with the Settings slider.
  - SB-01e docs: `docs/SKETCHYBAR.md` (config, `sketchybarrc`, plugin script, menu bar
    hiding), README, USER_GUIDE (`[hooks]`, `reserved-top`, `--json`, Install Command
    Line Tool, the CLI ships in the app), ARCHITECTURE.

## Evidence
- RED: the new tests (`WorkspaceBarStateTests`, `BarConfigTests`, rewritten
  `CLIInstallTests`, `BarHookNotifierTests`, `ShellHookRunnerTests`) were written first;
  `swift build --build-tests` failed to compile (`cannot find 'workspaceBarState'`,
  `'diffWorkspaceBar'`, `'encodeWorkspaceBarJSON'`, `'hookEnvironment'`, `'HookFlight'`,
  `'HooksSectionConfig'`, `'usableFrame'`, `'ShellHookRunner'`, type `'HookRunResult'`,
  ...).
- GREEN: `swift test` (2026-11-05): GioUITests 391 (54 skipped), GioSessionTests 630,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 131, GioCoreTests 2340, all 0 failures
  (run before the Settings slider). The full run after the slider: every bundle 0
  failures except GioUITests 1 failure, `LauncherPanelAnimationTests.testTheSlideInLandsOnTheRequestedFrame`
  (the panel stayed at its initial frame); it then failed alone three times in a row. It
  passed in the earlier full run and SB-01 does not touch `LauncherPanel`; it reads
  `NSScreen.main` and the live window server. The same test fails the same way at the base
  commit `254f890` (a temporary worktree), so it is environmental, not SB-01. Re-run it
  on an awake, unlocked desktop.
- Signed `xcodebuild` (scheme Gio, Debug): BUILD SUCCEEDED; the built app was unregistered
  (`lsregister -u`) and deleted.
- `git diff --check`: clean.
- The SketchyBar `sketchybarrc` snippet and `plugins/gio.sh` from `docs/SKETCHYBAR.md` ran
  under `/bin/bash` 3.2 with `/usr/bin/jq`, a fake `gio` printing sample JSON and a fake
  `sketchybar` echoing its arguments: the expected `--set space.N ...` arguments came out.

## Live status
NOT verified live: hooks firing in the running app, SketchyBar itself, the app binary in
CLI mode through the `~/.local/bin/gio` link (the built app was not launched in any mode),
Install Command Line Tool, the reserved band on real displays (scrolling, dwindle,
maximize, fullscreen), the Settings slider.
