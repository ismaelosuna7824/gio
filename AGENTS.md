# AGENTS.md

Instructions for AI coding agents working on Gio, a Niri-style scrollable tiling window manager for macOS (Swift, SwiftPM plus an Xcode app project). Read this first, then `docs/ARCHITECTURE.md` and `docs/CONTRIBUTING.md` before non-trivial changes.

## Repo map

| Path | What it is |
| --- | --- |
| `Sources/GioCore` | Pure logic. **No macOS UI/AX imports.** Registry, workspaces, layout, viewport, focus, move/resize, parking, motion planning, `WindowReconciler`, hotkeys, config, rules, IPC, logging, recovery, trackpad gesture recognition and the strip gesture's snap. |
| `Sources/GioMacOS` | macOS adapters: Accessibility (`AXWindowActuator`, discovery, events), `HotkeyTap`, the MultitouchSupport touch source (`dlopen`ed), displays, assemblies. |
| `Sources/GioUI` | SwiftUI/AppKit views and view models (main window, menu bar, launcher, settings). **Put new UI here.** |
| `Sources/GioSession` | Components extracted from `SessionHost` (publication, render verification, config coordination, IPC routing, snapshot flight and cache refresh, native zoom, motion driver and resize probes, focus coordination, window events and discovery, reflow planning, hotkey actions, trackpad gestures and their touch mailbox) plus the `SystemProbe`/`SessionScheduler` seams; session queue only, unit-tested with fakes and a virtual clock. |
| `Sources/GioDesktop` | `main.swift` (app delegate) and `SessionHost.swift` (the live session on the `gio.session` queue, composition root over `GioSession`). The Xcode `Gio` target compiles exactly these two files. |
| `Sources/GioCLI` | `gio` client; the SwiftPM target/binary is named `GioCLI`. |
| `Sources/GioPOC` | `gio-poc` AX proof of concept and `restore` recovery tool. |
| `Sources/GioMac`, `Sources/GioApp` | **Legacy** prototype. Do not extend. |
| `Tests/*` | One XCTest bundle per module: `GioCoreTests`, `GioMacOSTests`, `GioUITests`, `GioSessionTests`, `GioPOCTests`, `GioMacTests` (legacy). |
| `odd/tasks/*.md` | Feature documents: decisions, task IDs, commit hashes, evidence. |
| `docs/` | Architecture, testing, user guide, contributing. |
| `scripts/` | Release tooling: `make-dmg.sh` (signed, hardened `Gio.app` to a signed `Gio-<version>.dmg` plus `.sha256`), `release-version.sh` (the next version from the latest tag and a patch/minor/major bump, or a dry-run version; tests: `test-release-version.sh`), `swift-test-ci.sh` (CI test step: serial `swift test`, a failed case retried once as a warning) and `stamp-dev-version.sh` (Xcode build phase: dev builds report `<last tag>+dev`). See `docs/RELEASING.md`. |
| `.github/workflows/` | `ci.yml` (tests plus unsigned app build on every push), `prepare-release.yml` (manual, on `dev`: opens the release PR `dev` → `main` with a `release:patch|minor|major` label) and `release.yml` (every merge to `main`: version, test, then build and sign in the `release` environment, then publish a GitHub release and its tag; actions pinned by commit SHA). |
| `Gio.xcodeproj`, `Gio.xcworkspace` | Signed app project (scheme `Gio`) and helper schemes (`gio-poc-list`, `gio-poc-tile`, `gio-poc-restore`, `gio-doctor`). |
| `Resources/` | App icon: `AppIcon.icon`, an Icon Composer document (layers and `icon.json`) bundled by the Xcode `Gio` target; actool compiles it into `Assets.car` and `AppIcon.icns` (`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`). Edit it in Icon Composer and replace the folder; `applyBundleAppIcon()` (GioUI) hands the Dock the bundle's `AppIcon` at launch and whenever the window shows, to bypass a stale icon cache. |

## Commands

```sh
swift build                 # compile everything
swift test                  # all bundles (see pitfall: one "Executed" line per bundle)
swift test --filter GioCoreTests.WriteLaneTests     # one class
git diff --check            # whitespace check

# Signed app build (signing comes from Config/Signing.xcconfig + optional Config/Signing.local.xcconfig):
xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug \
  -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' build
```

## Hard rules (invariants)

1. **State is the source of truth.** Windows on screen are a projection of registry, workspace and display state.
2. **`LayoutEngine` and everything in `GioCore` know no macOS.** Do not import `AppKit`, `ApplicationServices`, SwiftUI or AX types into `GioCore`. Reach the OS through protocols Core owns (`WindowActuator`, `MotionFrameSink`).
3. **Only `WindowReconciler` writes window frames.** Flow: State, Layout, Reconciler, macOS. Never call AX from a hotkey handler, the UI or a use case. No exceptions: workspace-switch prepositions use `WindowReconciler.preposition`.
4. **Gio never manages, focuses or actuates its own pid.** Focus adoption, discovery and `AXWindowActuator.register` refuse it (commit `bac43c6`): AX calls on in-process elements run AppKit on the calling thread and crash. Every new enumeration or adoption path must keep these guards (`isManageableProcess`).
5. **Logs never contain window titles.** Log numeric IDs (`pid:elementID`), counts, timings and app names only.
6. **Business logic goes through pure Core use cases** with tests; hotkeys and IPC only map to actions. Return the input unchanged for a no-op.
7. **Session state mutates only on the `gio.session` queue.** Never nest `queue.sync` (deadlock). Do not add shared mutable state without a lock and a comment.
8. **Cocoa coordinates inside Core, AX coordinates only at the adapter boundary** (`AXVerticalFlip`). Layout frames are screen-space; `viewportOffset` is content-space; convert before comparing (fix `592c89d`).
9. **An invalid config never breaks the WM**, and config writes preserve unrelated lines and comments (`patchGioConfig`).
10. **Absence is not death.** Remove windows only on proof (destroyed event, terminated pid, complete scan).

## Workflow rules

- **Strict TDD is on:** write the failing test first (compile failure counts as RED), then the minimum code, then refactor. Put decisions in `GioCore`; keep adapters thin; inject clocks and I/O.
- **Conventional Commits, no `Co-Authored-By`, no AI attribution trailers.** One work-unit commit per task (behavior plus tests plus docs). Stage by explicit path. Do not push or open PRs unless asked.
- **Branches: commit to `dev`** (the default branch). `main` is protected and only takes the release PR from `dev`; every merge to `main` publishes a release. Never push to `main`, never tag by hand.
- Record non-trivial work in `odd/tasks/<feature>.md` with a task ID, the commit hash and evidence (RED, GREEN, executed counts, live status). Check off a task only after observing it.
- Do not edit generated or per-user state: `xcuserdata`, `.build/`, and scheme files that Xcode rewrites (`Gio.xcscheme`, `gio-poc-list.xcscheme` are often locally modified; leave them unstaged unless the task is about schemes).

## Pitfalls

- **The repository directory may be named `gio ` with a trailing space.** Quote every path in shell commands and scripts. Some tools trim it and fail (`lstat .../gio: not found`).
- **`swift test` prints one `Executed N tests` line per bundle**, plus an `All tests` line after each. The last line is only the last bundle. Read all of them (`swift test 2>&1 | rg "Test Suite '.*\.xctest' (passed|failed)" -A1`). Baseline: GioUITests 20, GioPOCTests 7, GioMacTests 19, GioMacOSTests 23, GioCoreTests 602.
- **Never run `gio-poc tile` against a live desktop** while Gio runs (or at all on a desktop you care about): it rewrites window frames and fights the session. Recovery: `swift run gio-poc restore`.
- **Never write the user's real config or files in tests.** `applyConfigEdits(_:toFileAt:)` defaults to `~/.config/gio/config.toml`, `loadGioConfig(at:)` reads the real path by default (`GioLog.logFilePath` defaults to a temp file under XCTest, HD-08), and `dispatch(.reload, ...)` re-reads the real config. Pass temp paths (see `ConfigPatcherTests`, `GioLogTests`, `CommandDispatcherTests`). Socket tests must use temp sockets.
- **The Xcode `Gio` target lists the `GioDesktop` files explicitly** in `Gio.xcodeproj/project.pbxproj` (`main.swift`, `SessionHost.swift`). A new file in `Sources/GioDesktop` will not be compiled by Xcode unless the pbxproj is edited. Put new UI and logic in `Sources/GioUI` or `Sources/GioCore`, which the app links as package products.
- **Never hard-code a version.** The app version is `MARKETING_VERSION` (`Config/Version.xcconfig`, the tag in releases) through Info.plist; code reads `gioVersion` (GioCore), which falls back to `gioBuildVersion` (`0.0.0-dev`) outside the app bundle. Releases come only from merging the Prepare Release PR into `main` (`docs/RELEASING.md`); never create tags or releases by hand.
- **Do not validate Accessibility behavior with `swift run GioDesktop`/`GioApp`.** They are not the signed app; the Accessibility grant is tied to code-signing identity. Use the Xcode `Gio` scheme. Signing lives in `Config/*.xcconfig` (`Signing.xcconfig` tracked defaults, `Signing.local.xcconfig` git-ignored personal override). Never edit `project.pbxproj` for signing and never commit signing changes.
- **The app re-executes itself as a guardian** (`Gio --guardian <pid>`, HD-07). Detect the flag before any `NSApplication` setup; the guardian must never take the lock, serve IPC or show UI. Protocol and decision logic: `GioCore/Commands/Guardian.swift`.
- **`SessionHost` and the views have no unit tests.** Extract the decision into Core, or the session-queue component into `GioSession` (closure context, `SystemProbe`, `ManualScheduler`), so it can be tested.
- **Exhaustive switches are guardrails:** adding a `HotkeyAction` case breaks `actionInfo` (ShortcutCatalog), `ActionApplier.apply` and `ActionApplier.applyDwindle` (`GioSession`, DW-02: choose the dwindle meaning, a no-op, or layout-independent), `carriesFocusIntent` and `motionCause`; adding a `CLICommand` case breaks `dispatch` and the launcher's `describeAction`; adding a `MainSection` case breaks `title`, `symbol` and `detail(for:)`. Follow the recipes in `docs/CONTRIBUTING.md`.
- **Key names are one shared vocabulary** (`supportedKeyNames` in `GioCore/Hotkeys/KeyNames.swift`) with a keycode per name in `tapKeyCodes` (`HotkeyTap.swift`); `HotkeyKeyTableTests` fails if they diverge. Unknown key names in config are validation errors.
- **Parsed-but-unused config:** themes are stored, not consumed. `behavior.focus-follows-mouse`, `behavior.mouse-follows-focus` and `layout.center-focused-column` are live (HD-04); `behavior.move-crosses-monitor-at-edge` is live through `ActionApplier.Context.behavior` and `CommandSession.config` (MM-06).
- **Only keyboard/IPC actions focus OS windows** (`FocusIntent`, HD-01). Passive reflows (AX events, click adoption, reload, rescan) pass `focused: nil`; never add a focus call to those paths or you will steal focus. Add new focus-moving actions to `HotkeyAction.carriesFocusIntent`. The one other deliberate input is a trackpad gesture: a vertical swipe applies `focus-workspace-*` like the hotkey, and a scroll's settle that focused another column calls `FocusCoordinator.requestGestureIntent()` (no centering, no cursor warp); nothing is focused while the fingers move (TG-03).
- **Never touch session state from MultitouchSupport's callback thread** (TG-03). The C callback only copies the contacts into a `TouchFrame` and posts it to `TouchFrameMailbox` (its own lock); the session queue drains it. `MultitouchSource` is started, stopped and re-registered on the main thread only, and the host keeps it alive until exit: its refcon is unretained and a callback may already be running when `stop()` returns.
- **While a trackpad scroll is tracking, `performReflow` returns at once** (`GestureController.isTracking`): the fingers own the strip and State does not move until the release, which (like the abandon) runs one pass that covers every request made meanwhile. A path that must write during a gesture does not exist; do not add one around the reconciler. The gesture's own frames go through `WindowReconciler` (`GestureFramePump`), never straight to AX.
- macOS refuses fully off-screen windows: parked windows keep a 1 pt sliver. Do not "fix" that by moving frames further out.
- **Never leave an app's `AXEnhancedUserInterface` off** (PF-K): VoiceOver users depend on it. A new frame-write path must go through `WindowReconciler` lanes, call `EnhancedUIGuard.willWrite(pid:)` before writing and end the batch in the lane's epilogue (`batchEnded`); a motion ends its batch at the app's final-pass lane or the settle (`restoreEnhancedUI`). Gio's own pid is never read or written.
- **Workspace layout kind (DW-01): column-only code must branch.** A workspace is `.scrolling` or `.dwindle` (`Workspace.layout`). In dwindle the columns are still the one membership list (one window each, in the tree's leaf order) and `Workspace.dwindle` is a view kept in sync by `WorkspaceManager` on every write; never store windows in the tree directly, and never assume `columns` order or widths mean geometry in dwindle. New layout-dependent code (geometry, scrolling, column actions, overview) must check `workspace.layout`.
- Legacy code (`GioMac`, `GioApp`, `TileLayout`, `NativeTilingCoordinator`, ...) still builds and has tests. Do not reuse it for new features.

## Where decisions live

`odd/tasks/` is the decision record. Read the file for the area you touch:

| File | Area |
| --- | --- |
| `gio-niri-rewrite.md` | Rewrite phases RW-00..RW-29: core, config, CLI/IPC, recovery, logging, unified app. |
| `window-coverage.md` | Admission, per-window observers, minimize, parking, restore on exit, click focus, reveal geometry, native window tabs (WC-01..WC-11). |
| `motion.md` | Timing, lean writes, per-app lanes, AX-driven animation (MO-01..MO-04). |
| `niri-controls.md` | Width presets, maximize, fullscreen, center, consume/expel, hidden workspaces, animated switch (NC-01..NC-07). |
| `desktop-app.md` | Main window, menu-bar lifecycle, settings, logs, diagnostics (DA-01..DA-05). |
| `workspace-overview.md` | Mission Control workaround, `toggle-overview` panel (WO-00..WO-01). |
| `fluidity.md` | Slow apps vs. the final pass, registration storms, unpainted windows, floating popups stealing focus, transient-window retries; a motion-following dim was tried and reverted (PF-A..PF-F). |
| `multi-monitor.md` | Multiple displays: primary-display flip, position order, startup placement, per-display parking, switch motion and widths (MM-01); monitor actions (MM-02); stacked displays and floating monitor moves (MM-03); no straddling, hot-plug, overview display, Move to Display, display log lines (MM-04). |
| `dwindle-layout.md` | Dwindle layout per workspace: tree model kept in sync with the columns, engine, planning, actions, config, overview/IPC (DW-01..). |
| `release.md` | Versioning, signed DMG, release workflow and its hardening (RL-01..RL-08) and the in-app updater and its hardening (UP-01..UP-17). |
| `trackpad-gestures.md` | Trackpad gestures (TG-01..): MultitouchSupport input, swipe recognizer, interactive strip scroll with a snapping spring, workspace and overview swipes, `[gestures]` config, macOS gesture conflicts. |
| `native-spaces-tiling.md`, `automatic-tiling.md`, `virtual-workspaces.md` | Older prototype history (pre-rewrite). |

## How to verify a change

1. `swift test`: every bundle reports 0 failures (read each `Executed` line).
2. Signed build: the `xcodebuild` command above succeeds (required when `GioMacOS`, `GioUI`, `GioDesktop` or the project changed).
3. `git diff --check`: clean.
4. For anything Accessibility-related, say plainly what was **not** verified live; automated tests and a green build do not prove live behavior. Use the checklist in `docs/TESTING.md`.
5. Report honestly: failed, skipped and pending checks belong in the report and in the feature document.
