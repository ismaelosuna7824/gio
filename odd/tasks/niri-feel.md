# Niri feel: focus ring and dynamic workspaces

## Objective
The two Niri traits with the most perceived impact and high macOS feasibility: a focus ring
that follows the active window, and Niri's dynamic vertical workspaces per display.

## Problem
- No visual indication of the focused window/column (Niri draws a focus ring).
- Workspaces are nine fixed slots (`WorkspaceManager`, Alt+1..9); Niri keeps a dynamic vertical
  stack per display with always one empty workspace at the end, and Mod+U/I style navigation.

## Why
User (2026-09-29) accepted the recommendation: live-verify pending work, then focus ring and
dynamic workspaces ("dale asi entonces").

## Scope (authorized)
NF-01 focus ring, NF-02 dynamic workspaces. Not yet: trackpad scroll, overview, spring and
open/close animations, tabbed columns, mouse move.

## Constraints
- Ring is a Gio-owned overlay window (never managed/actuated; own-pid guards), AppKit on main
  only, updated asynchronously from session publications (never block the session or main).
- Pure logic in GioCore with XCTest; only WindowReconciler writes managed windows.
- Conventional Commits, NO Co-Authored-By. Push to origin feat/gio-niri-rewrite after verified
  batches; no PR. Quote trailing-space path.

## Tasks
- [ ] NF-01 — Focus ring: borderless click-through overlay framing the focused window, follows
  reflows and motion frames, hidden when nothing is focused / Gio's window is frontmost /
  fullscreen; config `[focus-ring] enabled, width, active-color` (theme-aware default), settings UI.
- [ ] NF-02 — Dynamic vertical workspaces per display: always exactly one trailing empty
  workspace, empty non-focused workspaces removed, Alt+U / Alt+I focus workspace down/up,
  Alt+Shift+U / Alt+Shift+I move window down/up (creating the trailing one), Alt+1..9 index the
  stack, animated vertical switch reusing NC-07, hide/restore semantics preserved; app/menu bar
  and ShortcutCatalog updated.

## Acceptance criteria
- Ring visibly tracks focus during scroll animations without lag spikes or blocking hotkeys.
- Workspace stack grows/shrinks like Niri; windows never lost; quit/guardian restore everything.
- All 5 bundles green; signed build OK; docs updated.

## Applicable checks
- TDD: STRICT ON. Runner `swift test` (read all 5 "Executed" lines).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: UNAVAILABLE (gentle-ai trailing-space path defect; user chose continue).

## Routes
- NF-01 then NF-02: delegated writers, sequential (both touch SessionHost).

## Progress
- 2026-09-29: document created; live verification of FI-04 and earlier pending on the user. Next: NF-01.
