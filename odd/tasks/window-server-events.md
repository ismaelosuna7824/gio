# Window-server notifications (private SkyLight)

## Objective
Back up the per-app Accessibility observers with the window server's own notices of windows
being created and destroyed, so a window an app's observer misses still gets registered and a
closed window gets its proof scan at once.

## Why
User decision 2026-11-04, after comparing with OmniWM (which listens to SkyLight connection
notifications, `CGSEventObserver`): "sí vamos primero para las APIs privadas". OmniWM is
GPL-2.0; nothing was copied, only the documented-by-others shape of the calls.

## Constraints
- Read-only. PF-S (`3511e90`) showed SkyLight moves of other apps' windows do nothing on macOS
  27 (10 commits left the window in place), and WC-19 that `CGSSetWindowLevel` is refused; Gio
  keeps moving windows through Accessibility and `WindowReconciler` only (rule 3).
- Symbols resolved at runtime (`dlopen`/`dlsym`), never linked; a missing one turns the
  notifications off and Gio runs on Accessibility alone.
- Rule 10: a destroyed notice is not proof of death; it asks for the proof scan.
- Rule 4: never scan Gio's own pid, never read `_AXUIElementGetWindow` on its elements.

## Probe (throwaway, 2026-11-04, macOS 27, this Mac)
`SLSRegisterConnectionNotifyProc` for types 700-1400 (701 accepted) on `SLSMainConnectionID`,
`SLSRequestNotificationsForWindows` for the 10 on-screen windows, then activating apps and
opening and closing a Terminal window. Nothing arrived until the process ran an `NSApplication`
event loop (`nextEvent`); then, in 15 s: 806 x31 and 807 x8 (moved, resized; 4-byte window
number), 808 x19 (order), 811 x4, 815 x15, 1325 x1 and 1326 x1 (12 bytes: UInt64 space id,
UInt32 window number). `_AXUIElementGetWindow` returned the focused window's number (err 0).

## Tasks
- [ ] WS-01 (`5912de1`) — `WindowServerEventSource` (`GioMacOS`): `SkyLightEventSymbols.resolve`,
  registers 1325/1326 on the main thread at start (`window server events registered=N/2`, or
  `off missing-symbols:`), the C callback decodes (`decodeWindowServerEvent`, `GioCore`) and
  posts; `axWindowNumber` (`_AXUIElementGetWindow`) and `windowServerOwner` (public
  `CGWindowListCopyWindowInfo`). RED: compile (`WindowServerEventTests`,
  `WindowServerEventSourceTests`).
- [ ] WS-02 (`5912de1`) — `WindowServerWatcher` (`GioSession`): `WindowNumberBook` filled at
  registration (`registerHandles`) and cleared in `forgetWindow`; a created window still
  unknown after 1.5 s and still a layer-0 window of another app scans its app
  (`DiscoveryService.appAttached`, one per app per batch, `window server scan pid=N
  reason=unregistered`); a destroyed registered window calls `noteSettled(vanished:)`. RED:
  compile (`WindowServerWatcherTests`, 6).
- [ ] WS-03 (`f0b3b60`) — Moved/resized notices (806/807) for registered windows: the book's
  numbers are re-subscribed once per turn (`SLSRequestNotificationsForWindows`, on main;
  `window server subscribed windows=N` at debug); a burst per window becomes one
  `WindowEventRouter.windowServerFrameChanged` after 0.25 s, dropped when an AX moved/resized
  of that window arrived since (50 ms skew), the app is animating or a zoom is in flight, and
  otherwise handled by the same `handleFrameChange` as the AX event. RED: compile (Core
  `.moved`, watcher `frameChanged`/`subscribe`, router `windowServerFrameChanged`).
- [ ] WS-04 (`3c0a8c2`) — The recorded numbers replace the frame-matching guesses: snapshot capture
  (`SnapshotCaptureRequest.windowNumbers`, paint check, fresh capture, live streams; merged over the
  learned ids at match time by `snapshotKnownWindowNumbers`, never stored in
  `SnapshotWindowIDBook`), render verification (`ServerWindow.number` from `kCGWindowNumber`, a
  pass 0 by number in `matchServerWindows`), focus dim (`DimWindow.number` first in `serverIndex`),
  native zoom and resize probes (`known:` in the host closures). A number that is nil or no longer
  listed falls back to the frame rules. Not changed: `snapshotUndrawnWindows`,
  `unmanagedWindowFingerprint` (still by frame). RED (delegated writer): compile, then wrong or
  ambiguous matches for the render, dim and snapshot merge tests; the fallback guards and two
  context tests were never seen failing. GREEN: Core 2253, Session 598, UI 385 (54 skipped), POC 7,
  Mac 19, macOS 119; signed build OK. Live (2026-11-04T04:52Z, Fast preset with Screen Recording):
  `gio overview` captured `windows=10 captured=10 misses=0`, parked windows included.

## Evidence
GREEN: Core 2237, Session 584, UI 383 (54 skipped), POC 7, Mac 19, macOS 118; signed build OK;
`git diff --check` clean. Live (dev build, release removed, grants reset, 2026-11-04T03:38Z):
`window server events registered=2/2` before any grant, and again after the Accessibility
relaunch. With the grant (03:43Z, debug level for the run): a new Terminal window logged
`window server number id=24818:10 number=1524` next to its `window open` line (the number
came from `_AXUIElementGetWindow`); closing it, the AX destroyed event purged it first, so the
window server's notice found no number and did nothing; no `window server scan` line in the
session (no false scans for windows the AX path registers). NOT verified live: the rescue scan
  itself (needs an app whose observer misses a window; covered by `WindowServerWatcherTests`).
  Idle after the change: 0 s of CPU time over 60 s (`ps -o time`), RSS 128 MB (no footprint
  baseline taken in this session).
  WS-03 live (dev build, 2026-11-04T03:53Z, debug level for the run): the first build judged a
  notice at its handling time, 0.25 s after it came; Terminal snapping to its character grid
  right after Gio's write counted as a snap-back next to the late check, and Terminal yielded
  (`window yields to app id=24818:7 app=Terminal snapBacks=3`). Fixed in the same task: notices
  are judged at their own time, and a resize up to the late check after a write is the late
  check's (`testWindowServerFrameChangeIsJudgedAtTheNoticeTime`,
  `testWindowServerResizeBeforeTheLateCheckIsLeftToIt`, RED then GREEN). Rerun (04:10Z): the
  same AppleScript resize logged one `window server frame change id=24818:7 resized=true` and
  Terminal stayed `mode=tiled`. The debug line now appears only when a notice acts (Gio's own
  moves no longer log it).
- WS-05 (`6e51bee`) — Diagnostics (stability follow-up, user 2026-11-04 "necesitamos estabilidad"):
  a **Window server** card (`WindowServerStatus` in `SessionFacts`: notices registered of total or
  the missing symbols, notices received, rescue scans, windows with a number of managed), the
  Session card **Paused** while another window manager runs (WC-22), and the Displays card's
  `Displays have separate Spaces: on|off` detail, a warning with several displays (Gio's known
  gap: a Space change on a secondary display is not seen; OmniWM requires the setting on, but
  for Gio neither value is validated, so it informs and does not prescribe). RED: compile
  (`AdvancedPresentationTests`: card order, window-server card, displays warning, paused session;
  `WindowServerWatcherTests.testCountsNoticesRescueScansAndNumberedWindows`). GREEN: Core 2253,
  Session 599, UI 388 (54 skipped), POC 7, Mac 19, macOS 120; signed build OK. LIVE PENDING: open
  Diagnostics, read the Window server card.
