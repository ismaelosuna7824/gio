# Live fixes (2026-10-01)

## Objective
Fix two problems found while using the signed app: the onboarding Screen Recording step
looks stuck after the permission was granted, and fullscreen is lost when focus changes.

## Problem
- GitHub #4: `CGPreflightScreenCaptureAccess()` stays false until Gio relaunches, so the
  onboarding Screen Recording step shows a spinner and "Not granted" indefinitely
  (`Sources/GioUI/OnboardingView.swift` screenRecording step,
  `Sources/GioMacOS/Accessibility/ScreenRecordingPermission.swift`).
- GitHub #5: a window made fullscreen with Option+Shift+F (`.fullscreen`,
  `HotkeyDispatcher.swift:103`, NC-03 in `niri-controls.md`) returns to its split column
  when focus moves to another window.

## Why
User reports 2026-10-01. Issues https://github.com/ismaelosuna7824/gio/issues/4 and /5.

## Scope (authorized 2026-10-01)
Both fixes on the current branch `fix/gio-niri-build`. No commits until the user says so.

## Decisions
- #4: once access was requested, the step stops showing a spinner and offers "Relaunch Gio
  to apply", using the existing restart path; after that relaunch onboarding reopens on
  the Screen Recording step instead of the welcome step.
- #5: fullscreen is a per-window state cleared only by the toggle (or when the window
  closes or minimizes). Focusing another window moves focus as usual; focusing the
  fullscreen window again shows it fullscreen (Niri behavior).

## Constraints
- AGENTS.md hard rules; decisions in `GioCore`/presentation types with tests; no new
  comments in authored code (user rule); quote paths (trailing-space directory).

## TDD
Strict TDD on (AGENTS.md). Runner: `swift test`.

## Delivery
`ask-on-risk`; forecast well under 400 authored lines. No commits (user rule), so evidence
is uncommitted working-tree state; native review not run.

## Tasks
- [x] LF-01 — Fullscreen survives focus changes (#5). Route: delegated writer.
  DONE, UNCOMMITTED. Cause: `SessionHost` called `fullscreen.release(keeping: focused…)`
  at the start of every reflow pass (`FullscreenBook.release`), so any focus change that
  reflowed ended fullscreen; `fullscreenWindow` (`DisplayReflowPlanner.swift`) also fell
  back to the first fullscreen window when focus was elsewhere. Fix: `FullscreenBook.prune
  (registry:)` drops only records whose window is gone or no longer fullscreen; the
  planner covers the display only when the focused window is fullscreen (or nothing is
  focused) and otherwise lays fullscreen windows out in their columns with their mode
  kept. Docs: USER_GUIDE Alt+Shift+F row, TESTING row 8. Evidence: RED compile failure
  (`no member 'prune'`) then 4 assertion failures; GREEN FullscreenTests 16/0; `swift
  test` 1814 executed, 53 skipped, 0 failures (parent re-ran); signed build OK; diff
  --check clean. LIVE PENDING. Gaps: restored column frame lands on the next reflow; host
  prune call untested; workspace switch/multi-display with a non-focused fullscreen
  window not exercised.
- [x] LF-02 — Screen Recording step offers relaunch (#4). Route: delegated writer.
  DONE, UNCOMMITTED. Pure `PermissionStepPhase` (notRequested / awaitingRelaunch /
  granted) via `screenRecordingStepPhase(granted:requested:)`; `shouldShowOnboarding`
  takes a `resumeStep`. `OnboardingStore` stores `GioOnboardingResumeStep`
  (`markResume`/`clearResume`/`consumeResumeStep`); `OnboardingPresenter.prepareRelaunch
  (at:)` sets it, `evaluate` consumes it once and opens on that step, `finish`/`later`
  clear it. Step: neutral before a request, "Granted it?…" plus prominent "Relaunch Gio"
  after one. `DesktopActions.relaunch` → `SessionHost.requestRestart()` → existing
  `onRestart` (`restartSession` + `relaunchGio`, `--after-restart` lock handoff).
  Overview/Diagnostics requests mark the request but do not set the resume marker.
  Docs: TESTING row 15f, USER_GUIDE sentence. Evidence: RED compile failures
  (`cannot find 'screenRecordingStepPhase'`); GREEN `swift test` 1823 executed, 53
  skipped, 0 failures (parent re-ran); signed build OK; diff --check clean. LIVE PENDING.
  Gaps: request flag is in memory only; Overview row has no relaunch button.

- [x] LF-03 — Fullscreen window shrinks and regrows on every focus change (live report
  2026-10-01, follow-up to LF-01, #5). Evidence: VS Code resized to 1336x832 six times in
  ~6 s, spring animations of 2.9 s with `grewAtStart=1`. Cause: LF-01 laid an unfocused
  fullscreen window out at its tiled column width. Decision (Niri, user confirmed "I don't
  want it to shrink when it loses focus"): a fullscreen window keeps its fullscreen size
  as a full-width column; focus changes only scroll. Route: delegated writer. DONE,
  UNCOMMITTED: `DisplayReflowPlanner` `layoutKeepingFullscreenSize` widens a planning
  copy of the fullscreen window's column to `.points(fullscreenFrame.width)` and forces the
  fullscreen size/y (stored `widthSpec` untouched, so the toggle restores it); covering
  path unchanged. RED 8 failures/4 tests (880x436 instead of 1800x976); GREEN
  FullscreenTests 19/0; `swift test` 1826 executed, 53 skipped, 0 failures (parent
  re-ran); signed build OK; diff --check clean. LIVE PENDING. Gaps: tiled siblings in the
  same column get full width; a learned min width larger than fullscreen is overridden.

## Acceptance criteria
- A fullscreen window stays fullscreen across keyboard and click focus changes and only
  leaves fullscreen through Option+Shift+F (or close/minimize).
- After requesting Screen Recording, onboarding offers a relaunch; after relaunching it
  reopens on the Screen Recording step showing the permission as on.
- `swift test` 0 failures; signed `xcodebuild` succeeds; `git diff --check` clean.

## Progress
- 2026-10-01: document created; issues #4 and #5 filed.
- 2026-10-01: GitHub Project 1 status set to "In progress" for #4 and #5 (fixes uncommitted, live pending).

## Next step
Live check (TESTING rows 8 and 15f); the user decides on commits. GitHub board already
set to "In progress".
