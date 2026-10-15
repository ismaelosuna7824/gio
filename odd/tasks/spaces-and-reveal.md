# Foreign Spaces and OS-focus reveal

## Objective
Gio must not move or hide windows when the user visits another macOS Space, and a
window that macOS focuses on its own (App Exposé, Mission Control, Dock) must become
visible even when it lives on a hidden Gio workspace.

## Problem (diagnosis 2026-09-30, code reading, not reproduced live)
- GitHub #1: Gio has no Space handling (`docs/TESTING.md:214`; no
  `activeSpaceDidChangeNotification` outside legacy `GioApp`). On a new Space an app
  activates (often Finder), focus adoption registers its window as a new column on the
  current Gio workspace (`FocusCoordinator.swift:343-347`, `DiscoveryService.swift:349-355`)
  and `reflowAll()` parks every window of the managed Space off screen (log:
  `reconcile failure ... requested=(-663,…) kind=timeout`). Back on the managed Space
  nothing restores them.
- GitHub #2: `FocusCoordinator.adoptFocus` only searches `context.currentWorkspace()`
  (`FocusCoordinator.swift:213`); `adoptingFocus` (`GioCore/Focus/FocusAdoption.swift:32`)
  returns nil for a window on another Gio workspace, so an OS-focused window stays parked.

## Why
User report 2026-09-30: windows vanish after visiting a new Desktop; a Chrome window
picked with Control+Down does not appear. Issues
https://github.com/ismaelosuna7824/gio/issues/1 and /2.

## Scope (authorized 2026-09-30)
Fix both issues on the current branch `fix/gio-niri-build` (same base `b881fc8`). Out of scope: tiling other Spaces
(multi-Space support stays a documented limit), moving windows between Spaces.

## Decisions
- Other Spaces are left alone, not tiled: while the active Space is not the managed one,
  Gio adopts nothing, registers nothing and writes no frames. Returning re-places the
  managed windows with one reflow.
- The managed Space is detected with public API only (no private CGS calls).
- Reveal applies to OS focus signals (AX focused-window change, app activation), never to
  passive reflows; HD-01 holds: Gio switches the workspace without issuing its own focus
  call, because the OS already focused the window.

## Constraints
- Decisions in `GioCore` with tests; adapters thin (AGENTS.md hard rules 2, 3, 6, 7).
- Gio never manages its own pid (rule 4); logs carry no window titles (rule 5).
- No commits until the user says so (user rule 2026-09-29, reaffirmed 2026-09-30).
- Directory may have a trailing space; quote paths.

## TDD
Strict TDD on (source: AGENTS.md "Strict TDD is on"). Runner: `swift test`
(`swift test --filter <Bundle>.<Class>` for focused runs).

## Delivery
Strategy `ask-on-risk`; forecast under 400 authored lines. User forbids commits for now,
so tasks close with uncommitted working-tree evidence instead of commit hashes, and the
native review (which reviews commits) is not run.

## Tasks
- [x] SR-01 — Foreign-Space gate (#1). Route: delegated writer (2+ non-trivial files).
  DONE, UNCOMMITTED (user rule). Core `SpaceGate` (left/returned transitions);
  GioSession `SpaceCoordinator` (logs `space foreign; pausing layout` / `space managed;
  reflow`, discards pending adoptions on leave, one `reflowAll` with no focus on return);
  GioMacOS `ManagedSpaceMonitor` (1 pt transparent `.floating` marker NSWindow on the
  starting Space, `isOnActiveSpace` read on main on `activeSpaceDidChangeNotification`,
  async hop to the session queue). Gated: `DiscoveryService` (enumerate/purge,
  attach, activate, every registration attempt), `FocusCoordinator` (request/adopt/
  resolve), `SessionHost` reflow scheduling (dropped, not queued). Docs: TESTING.md limit
  rewritten, checklist row 15d. Evidence: RED compile failures (`SpaceCoordinator`,
  `allowsWindowWork`, `discardPendingAdoptions` missing); GREEN `swift test` 1805
  executed, 53 skipped, 0 failures (parent re-ran); signed xcodebuild BUILD SUCCEEDED;
  diff --check clean. Parent removed writer-added doc comments (user no-comment rule).
  LIVE PENDING: Space detection, marker invisibility, return reflow, fullscreen and
  multi-display. Residual gap: an activation delivered before the Space notification can
  still admit one foreign window; hotkeys/IPC while away change state, reflow on return.
- [x] SR-02 — Reveal OS-focused window on a hidden Gio workspace (#2). Route: delegated
  writer. DONE, UNCOMMITTED. Reused pure Core `planFocusWindow(_:in:)`
  (`FocusWindowPlan.swift`, already tested; nil for unknown/floating). In
  `FocusCoordinator.adoptResolved`, a plan that switches workspace cancels any focus
  intent (HD-01: no Gio focus call, next reflow `focused: nil`), calls `showWorkspace`
  (`manager.focus`, `syncShownWorkspace`, `.workspaceSwitch` motion cause, like keyboard
  switches), adopts the window, logs `focus reveal id=<pid:elementID> workspace=<n>
  source=<focusChanged|activation>` and reflows. Only `.focusChanged`/`.activation`;
  the OS-reported element decides. The 2 s keyboard-intent ignore window still wins.
  Evidence: RED compile failure (`extra arguments at positions #22, #23`); GREEN
  FocusCoordinatorTests 31/0; `swift test` 1811 executed, 53 skipped, 0 failures (parent
  re-ran); signed xcodebuild BUILD SUCCEEDED; diff --check clean. Writer stalled once
  after RED and was resumed. LIVE PENDING: Exposé/Mission Control/Dock picks, switch
  animation without intent, keyboard focus kept. Gaps: `.workspaceSwitch` cause untested;
  host closures untested; an app activating itself on another workspace now switches
  there; move-window-to-workspace relies on the 2 s intent window not to bounce.
- [x] SR-03 — Docs. Inline with SR-01/SR-02: `docs/TESTING.md` limit rewritten, live
  checklist rows 15d (Spaces) and 15e (Exposé); `docs/USER_GUIDE.md` Workspaces bullet.

- [x] SR-04 — Onboarding Continue stays disabled after granting Accessibility (#3,
  found during live testing). Route: inline (one view + one presentation type).
  `OnboardingContent` mirrored the permission in `@State` and refreshed it from
  `onChange(of:perform:)`, whose closure reads the previous render's `self`, so the copy
  stayed false. Now the view derives `current` from `OnboardingState.updating(...)` with
  the live inputs; `onChange`/`sync()` removed. DONE, UNCOMMITTED. RED: `no member
  'updating'`; GREEN `swift test` 1812 executed, 53 skipped, 0 failures; signed build
  OK; diff --check clean. LIVE PENDING.
- [ ] SR-05 — Live report 2026-10-01: picking a window in Mission Control/App Exposé, or
  opening an app from Raycast/Spotlight, does not bring it into view. Evidence: log
  alternates `space foreign` / `space managed` 1-6 s apart (8 pairs 03:36-03:37): macOS
  reports Mission Control/Exposé as an active-Space change and the marker is not on the
  active Space meanwhile, so SR-01 closed the gate and the pick's activation/focus events
  were dropped; the return only reflowed. Fix (inline, UNCOMMITTED): `SpaceCoordinator`
  context gains `adoptFrontmostFocus`, run on return before the reflow; `SessionHost`
  wires it to `focus.requestAdoption(.activation, pid: frontmost, element: nil)`, which
  reads the app's current `AXFocusedWindow` and reveals/scrolls through SR-02. RED: `extra
  argument 'adoptFrontmostFocus'`; GREEN `swift test` 1813 executed, 53 skipped, 0
  failures; signed build OK; diff --check clean. LIVE PENDING. Open: whether Spotlight/
  Raycast also toggle the Space or fail elsewhere (needs `[logging] level = "debug"`);
  returning from a real other Desktop adopts whatever app macOS puts in front.
- [ ] SR-06 (commit pending, branch `fix/johan-spaces-safari`) — Report (johan, 2026-10-14): two apps sent to
  Desktop 2, then brought back to Desktop 1 (Gio's Space), stayed behind the tiled windows and could not be
  reached; opening them from Raycast moved them to a workspace 2. Code reading (no log yet): discovery
  lists AX windows of the active Space only and nothing announces a window that changed Space, so windows
  moved into the managed Space are never registered until something focuses them. Fix: on the return to the
  managed Space `SpaceCoordinator` runs `rescan` (host: `discovery.enumerateAndPlace()` +
  `events.syncObservers()`, a full add-only scan: new windows land on the display they sit on, never follow)
  before `adoptFrontmostFocus` and the reflow. RED: `SpaceCoordinatorTests` compile failure (`extra argument
  'rescan'`); GREEN: events `rescan, adopt, reflow`; bundles UI 310 (53 skipped) / Session 481 / POC 7 /
  Mac 19 / MacOS 95 / Core 1971, 0 failures; signed build OK. Open: why Raycast put them on "workspace 2"
  (needs johan's `gio.log` around 23:24). LIVE PENDING: move a window from Desktop 2 into Gio's Desktop.

## Acceptance criteria
- Visiting another Space and returning leaves every managed window where it was.
- Windows of another Space are never registered or moved by Gio.
- Picking a window on a hidden Gio workspace in App Exposé switches to that workspace and
  shows the window; picking one on the current workspace still scrolls to it.
- `swift test` 0 failures; signed `xcodebuild` succeeds; `git diff --check` clean.

## Checks
`swift test`, signed `xcodebuild` (Gio scheme), `git diff --check`, live checklist
(not automatable: Spaces and App Exposé need a real desktop).

## Progress
- 2026-09-30: document created; issues #1 and #2 filed. Project board status update
  blocked: `gh` token lacks the `project` scope.
- 2026-10-01: GitHub Project 1 status set to "In progress" for #1, #2 and #3 (fixes
  uncommitted, live pending).

## Next step
SR-05 evidence first. Live check of TESTING.md rows 15d and 15e in the signed app; then the user decides
on commits. Project board status pending the `project` gh scope.
