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
NF-01 focus ring, NF-02 dynamic workspaces. Not yet (trackpad deferred by user 2026-09-29): trackpad scroll, overview, spring and
open/close animations, tabbed columns, mouse move.

## Constraints
- Ring is a Gio-owned overlay window (never managed/actuated; own-pid guards), AppKit on main
  only, updated asynchronously from session publications (never block the session or main).
- Pure logic in GioCore with XCTest; only WindowReconciler writes managed windows.
- Conventional Commits, NO Co-Authored-By. Push to origin feat/gio-niri-rewrite after verified
  batches; no PR. Quote trailing-space path.

## Tasks
- [x] NF-01 (`9680776`) — Focus ring: borderless click-through overlay framing the focused window, follows
  reflows and motion frames, hidden when nothing is focused / Gio's window is frontmost /
  fullscreen; config `[focus-ring] enabled, width, active-color` (theme-aware default), settings UI.
- [x] NF-02 (`1fa9e24`, `8ccaf4a`) — Dynamic vertical workspaces per display: always exactly one trailing empty
  workspace, empty non-focused workspaces removed, Alt+U / Alt+I focus workspace down/up,
  Alt+Shift+U / Alt+Shift+I move window down/up (creating the trailing one), Alt+1..9 index the
  stack, animated vertical switch reusing NC-07, hide/restore semantics preserved; app/menu bar
  and ShortcutCatalog updated.

Evidence NF-01 (route: delegated writer): pure focusRingState (hidden: disabled/width 0/no focus/
minimized/fullscreen/off-viewport <24pt), LatestValueMailbox coalescing, `.floating`
non-activating click-through panel, published per reflow/adoption/reload/motion tick (no AX).
Color: active-color > theme borderActive > #7fc8ff. 30 tests RED -> GREEN; bundles 20/7/19/30/679
all 0 failures (parent re-ran); signed build OK. Gaps: user-dragged floating window ring stale
until next reflow; ring tracks session focus, not unmanaged frontmost apps. LIVE PENDING.
Review: UNAVAILABLE.

Evidence NF-02 (route: delegated writer): per-display stacks with stable ids, one trailing empty,
empty non-current removed on leave; Alt+U/I, Alt+Shift+U/I (follow window), Alt+1..9 index
(beyond -> trailing empty); rules `workspace = N` = index at arrival (no in-between creation,
would be pruned); status adds `stacks`; 3000-op seeded property test. Bundles 22/7/19/30/697
all 0 failures (parent re-ran); signed build OK. Gaps: move-workspace up/down, CLI up/down verbs.
LIVE PENDING. Review: UNAVAILABLE.
- [x] NF-03 (`eccbc67`) — Focus ring color picker in the desktop app (user request 2026-09-29, "haz que se
  pueda cambiar el color desde la desktop app"). Route: delegated writer. DONE: ColorPicker (sRGB, no
  opacity) + presets + hex field + preview; normalizedHexColor; 8 tests RED -> GREEN; bundles
  22/7/19/30/705 all 0 failures (parent re-ran); signed build OK. LIVE PENDING.
- [x] NF-04 (`2768b44`) — Spring animations (user approved 2026-09-29): critically damped spring (Niri
  view-movement default: damping-ratio 1.0, stiffness 800, epsilon 0.0001) replacing ease-out;
  retarget preserves velocity; `[animations]` gains `curve = "spring" | "ease-out"`, spring
  params; position-only motion rules (FI-03) kept. Route: delegated writer (shared with FI-06).
  DONE: analytical spring (under/critical/over), velocity-preserving retarget, 1s cap,
  curve/damping/stiffness config + UI. Bundles 22/7/19/32/768 all 0 failures (parent re-ran);
  signed build OK. LIVE PENDING.
- [x] NF-05 (`a8b0c13`) — Fullscreen gap (user request 2026-09-29: fullscreen touched every edge):
  `[layout] fullscreen-gap` (unset = gaps, 0-64), frame inset on all sides under the menu bar,
  focus ring shown in fullscreen when gap >= ring width; settings toggle + slider. Route:
  delegated writer. Bundles 22/7/19/32/779 all 0 failures (parent re-ran); signed build OK.
  LIVE PENDING. Review: UNAVAILABLE.
- [x] NF-06 (`526ca83`, `72cae26`, `80b01ff`) — Focus indicator: dim inactive windows (user chose option A 2026-09-30: the ring
  "chases" windows during motion and looks non-native). At rest only: visible unfocused tiled
  windows dim ~15% (fade in at settle, fade out at motion start), computed from Gio's frames minus
  anything in front (CGWindowList on-screen order); click-through overlay; ring off by default;
  `[focus] indicator = dim|ring|none`, `dim-strength`. Plus: startup layout instant (no fly-in
  animation; live screenshot caught the first layout mid-flight) and atomic cross-process log
  lines (guardian line split a main-process line). Route: delegated writer.
  DONE: FocusDim (window-server rects front-to-back, subtract front windows + focused, clip per
  display), level normal+1 panels, fade 150/80ms (no fade with Reduce Motion), dark 80% strength,
  hidden during AX/snapshot/zoom flights and user drags; `[focus] indicator` default dim; startup/
  permission-regain placement instant (`layout instant reason=`); O_APPEND single-write batches,
  main-only rotation, reopen after rename. Observed RED each. Bundles 45(5 skipped)/7/19/39/1120
  all 0 failures (parent re-ran); signed build OK. LIVE PENDING.
- [x] NF-07 (`5cf9eb7`, branch `fix/johan-spaces-safari`) — Live (2026-10-15, screenshot): a floating
  window (Finder, floated by rule) kept the ring at its old frame while the user dragged it (NF-01's known
  gap: Gio does not follow a floating window's own moves). Decision: no ring for floating windows
  (`FocusRingWindow.isFloating`, hidden in `focusRingState`; both the live ring and the overlay's flight copy
  pass it). Supersedes the USER_GUIDE line "Floating windows get the ring too". RED:
  `FocusRingTests.testHiddenForAFloatingWindow` compile failure (`extra argument 'isFloating'`); GREEN.
  LIVE PENDING: focus a floating Finder window, no ring.
- [x] NF-08 (`133ffd7`, branch `fix/johan-spaces-safari`) — The ring is the default focus
  indicator (user choice 2026-10-15, after the PF-U..PF-AB measurements showed no meaningful cost
  difference: in the throwaway compositor experiment both panels were within the noise, and the
  ring's per-tick refresh was ~2 % of Gio's CPU in the heaviest run). `FocusSectionConfig` defaults
  to `.ring`; the template writes `indicator = "ring"`; configs that already say `"dim"` keep it.
  Docs: USER_GUIDE (`[focus]` row and example), ARCHITECTURE (focus dim bullet), TESTING 15c (set
  the dim explicitly). RED: `FocusDimTests.testDefaultsAreTheRingWithTheDimAtFifteenPercent`
  ("dim" is not equal to "ring"); `FocusDimPublisherTests` now set the dim in `setUp`; the
  template wording pin was dropped (the template still must parse to the defaults). GREEN: all
  bundles 0 failures (UI 312/53 skipped, Session 484, POC 7, Mac 19, MacOS 98, Core 1965); signed
  build OK. LIVE PENDING: a fresh config (no `indicator` key) shows the ring.
- [ ] NF-09 (`2a254bc`) — Ring off when the focused window is the only visible one, and thinner by default
  (user request 2026-11-03, screenshot: a lone column filling the screen wore a 4 pt frame around
  the whole display; "que se quite el borde… si hay que ponerlo, reducir los puntos… que sea más
  tenue"). `hide-when-maximized` never suppressed it: a wide column without a saved width spec is
  not "maximized". `[focus-ring] hide-when-alone` (default true): no ring when no other tiled window
  is visible on the display that holds the focused one (a parked column's 1 pt sliver, a minimized
  window or a neighbour on another display does not count). Pure `focusRingIsAlone` +
  `focusRingState(..., alone:)`, fed by the live publisher (physical frames of the shown workspace)
  and by the snapshot overlay's flight copy (landing frames); `hide-when-alone` in the parser, the
  template, `focusRingEdits`/`FocusRingSettingsForm` and the Settings toggle "Hide when it is the
  only window". `FocusRingSectionConfig.defaultWidth` 4 -> 2 (template and USER_GUIDE too).
  RED: `OverlayDecorationsTests` `extra argument 'alone'`, and `'hideWhenAlone'` before the config
  field existed. GREEN: Core 2210, Session 577, UI 375 (53 skipped), POC 7, Mac 19, macOS 116
  (2 skipped) — its one failure, `UpdatePreparerTests.testSetIDItemsNeverReachTheStagedCopy`, is
  environmental: the agent sandbox drops the setuid bit the fixture needs, and it reproduces outside
  this change. Signed build OK. LIVE PENDING: rebuild the app, focus a lone column, no ring.
  **Follow-up (`2bdc186`, live 2026-11-03 07:09)**: the user wants the ring back on a maximized
  column ("con Alt+F también debe salir"). Maximize no longer hides the ring, and a maximized column
  never counts as alone (`focusRingState` exempts it), so `Alt+F` shows the level indicator at 2 pt.
  The hide key became `hide-in-fullscreen` — the old `hide-when-maximized` still parses into it — and
  the Settings toggle reads "Hide in fullscreen". RED: `FocusRingTests.testMaximizedColumnKeepsItsRing`
  and the renamed round trip, `FocusRingPublisherTests.testMaximizedColumnKeepsTheRing`, the
  overlay's maximized expectation. GREEN: Core 2210, Session 577, UI 375 (53 skipped), POC 7, Mac 19,
  macOS 116 (2 skipped, same environmental failure); signed build OK. LIVE PENDING: rebuild, `Alt+F`,
  the ring stays.
- [x] NF-10 (`416570d`) — No ring on some focused windows (user report 2026-11-03, screenshot: Terminal
  focused next to Zen, no ring; "solo algunas y otras no"). Reproduced live on 0.1.4 (activating Zen
  shows the ring panel at Zen's frame, activating Terminal shows none; debug log `focus ring hidden`
  right after `focus adopt ... id=37822:5`). Cause: Terminal keeps its character-grid size
  (requested 744x933, actual 741x934), every write reports `frameMismatch`, and `foldSettle` forgot
  the physical frame of every failed window, so `FocusRingPublisher` had no frame (ring hidden) and
  the window dropped out of the neighbour/dim checks. Fix: `foldSettledPhysicalFrames` (GioCore)
  records a failed window at the actual frame its failure reports (mismatch); other failures,
  vanished and deferred windows are still forgotten. RED: compile (`foldSettledPhysicalFrames`
  missing). GREEN: Core 2228, Session 577, UI 381 (54 skipped), POC 7, Mac 19, macOS 116; signed
  build OK. LIVE (Debug build with NF-10/NF-11, 2026-11-03 21:51Z, release removed): Terminal focused
  next to OrbStack shows the ring at (6,39,745,938), Terminal's 741x934 frame outset by 2, 4 of 4 runs.
  Same cause behind the overview report (2026-11-03, "click desde aquí ... no le pone el aro"): the
  log's picks at 21:36:48 and 21:38:40 are `focus window requested id=37822:4` (Terminal), and every
  write to it fails `frameMismatch`; System Settings (740 wide) is the other window affected
  this session.
- [x] NF-11 (`ff3d04b`) — Alt+O pick onto another app's window often left it without a ring (user report
  2026-11-03, on the Xcode build that already had NF-10, picking OrbStack). Reproduced (debug log,
  `gio overview` + arrow + Return): picking OrbStack from Terminal logs `focus ring hidden` at the pick,
  before the reconcile, and no `focus ring shown` until another app is activated; picking the window
  already focused keeps the ring; intermittent (one of three runs showed it). The FX-01 lead publish
  reaches `FocusRingController` while the overview's non-activating key panel makes
  `NSApplication.isActive` read true, so the mask hid it, and no app activation notification of Gio's
  followed to refresh it. Fix: the mask reads `NSWorkspace.frontmostApplication` (Gio's pid) and the
  controller also refreshes on `NSWorkspace.didActivateApplicationNotification`. Main-thread overlay,
  no unit test (no window-server harness). GREEN: Core 2228, Session 578, UI 381 (54 skipped), POC 7,
  Mac 19, macOS 116; signed build OK. LIVE (same build): Terminal focused, `gio overview`, Right,
  Return onto OrbStack: ring at OrbStack's frame after the pick in 4 of 4 runs (before: 2 of 3 had none);
  with Gio's main window frontmost the ring stays hidden, back on OrbStack's activation.
- [x] NF-12 (`bb75518`) — Regression of NF-11 in 0.1.5: the ring showed through the Alt+O overview
  (user screenshot 2026-11-03, the ring's frame across the overview's tiles). The overview and the
  launcher are non-activating panels, so another app stays frontmost and the frontmost-only mask let
  the ring show; before NF-11 `isActive` had hidden it. Fix: the mask is "Gio is frontmost or one of
  its windows is key", refreshed on Gio's window key changes (now and on the next turn, once AppKit
  updated the key window) and every app activation, so NF-11's pick still shows the ring once the
  overview gives up key. RED: none (main-thread overlay, no harness). GREEN: Core 2228, Session 578,
  UI 383 (54 skipped), POC 7, Mac 19, macOS 116; signed build OK. LIVE (dev build, clean grants,
  2026-11-04): `gio overview` open, no ring panel listed (only the overview's screen-sized panel);
  after a pick the ring sits at the picked window's frame.
- [ ] NF-13 (`PENDING`) — The ring drew over Gio's own window (user screenshot 2026-11-04: its edge
  across the Overview while System Settings had the focus). The panel sat at `.floating`, above
  every ordinary window. Now `FocusRingGeometry.windowNumber` (the focused window's number from the
  WS-02 book, `FocusRingPublisher` context) puts the panel at `.normal`, ordered right above that
  window (`order(.above, relativeTo:)`; throwaway probe: a panel lands one place in front of
  another app's window, two of two); whatever covers the window covers the ring. A click raising
  the focused window over the ring posts 808 (subscribed): the watcher passes `.reordered`, the
  host calls `focusedWindowReordered` and the ring is put back. No number: `.floating` as before.
  `FocusRingPublishGate` publishes a change of number at the same frame. RED: compile (publisher
  `windowNumber`, gate, Core 808 decode, watcher `reordered`). LIVE (dev build, 2026-11-04): z-order
  front to back `Gio main window > System Settings > ring > Activity Monitor` (focused), then `ring >
  Music`, `ring > Terminal` after activating each. Not verified live: a click raising the focused
  window (no click into it was posted).

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
- 2026-09-29: NF-01 done, pushed. Next: NF-02.
- 2026-09-29: user live: likes focus ring; asked color picker (NF-03); reported right-side empty area until Alt+J — under diagnosis (center-focused-column=always vs Chromium occlusion repaint). NF-02 done, pushed.
- 2026-09-29: NF-03 done, pushed. Open question to user: was the empty right area the last column (center=always) or a missing window (Chromium occlusion repaint)?
- 2026-11-03: NF-09 (hide-when-alone + 2 pt default) red -> green, signed build OK; live check pending after rebuilding the app.
