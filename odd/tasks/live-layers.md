# Live layers (LL)

Objective: during a snapshot flight, the layers of moving, visible windows show live content streamed with
ScreenCaptureKit (`SCStream`) instead of a still cached image. Branch `fix/stale-flight-snapshots` (after
SM-35, uncommitted; commits wait for the user's approval). Delivery: `ask-on-risk`. Runner: `swift test`.

## Specs

- S1 — A moving, visible window's layer shows its live content while it flies. User: "Still very back in
  time, why not something more inmediate?, I mean I'm testing with a youtube video and it just gets there";
  decision: "go with live layers". A playing video keeps playing while its window slides.
- S2 — Until a window's stream delivers its first frame, its layer shows the cached image as today (SM-11,
  SM-24, SM-35 rules unchanged); a stream that fails or never delivers leaves the cached image, never a hole.
- S3 — Streams run only during a flight: they start when the flight begins (and for windows a retarget
  adds) and stop on every flight exit (hand-off, fade-out, abort, end, failed prime). Assumption: at most
  `liveLayerMaxStreams` (4) at once, windows landing on screen first; still (FX-09 see-through) layers,
  opening (WP-04/05) windows and windows that change size (SM-30 keeps them) are not streamed in v1.
- S4 — Invariants: Gio never streams its own pid; logs carry `pid:elementID`, counts and timings only, never
  titles; session state mutates only on `gio.session`; stream frames go from the capture queue to the
  overlay on the main thread without passing through the session queue; a stream never writes frames
  (reads pixels only); GioCore stays free of ScreenCaptureKit, IOSurface and CoreMedia.
- S5 — Measurable: debug `live layer start count=N`, `live layer first frame id=P:E ms=N` (time from start
  request to first complete frame) and `live layer stop count=N frames=N`, so a live session shows whether
  the first frame lands early enough in a ~400 ms flight.

## Tasks

| ID | Specs | Route | Status | Evidence |
| --- | --- | --- | --- | --- |
| LL-01 | S3, S5 | inline | done (uncommitted) | `Sources/GioCore/Snapshot/LiveLayers.swift`; RED: `LiveLayersTests` compile failure (`liveLayerMaxStreams` missing); GREEN: 4 tests, 0 failures |
| LL-02 | S1, S2, S4, S5 | delegated (parallel unit, GioMacOS) | done (uncommitted) | `LiveWindowStreamer` (one `SCStream` per window, 60 fps, BGRA, queueDepth 3, generation guard, own pid skipped, cap 4); `SnapshotCapturer.liveWindows`, shared `windowCaptureConfiguration(pixels:)`; RED: compile failure (`LiveStreamBook`); GREEN: 9 tests, GioMacOSTests 116, 0 failures. Handler runs under the streamer lock: it must only hop to main. Live pending: latency, frame rate, surface reuse |
| LL-03 | S1, S2, S4 | delegated (parallel unit, GioUI) | done (uncommitted) | `showLive`/`clearLive` on `SnapshotOverlayController`, one live sublayer in the clip above image and faces, dropped on every overlay exit; RED: compile failure; GREEN: `SnapshotOverlayLiveTests` 13, GioUITests 374 (53 skipped), 0 failures. Live pending: surface orientation and fit |
| LL-04 | S2, S3, S4 | delegated (parallel unit, GioSession) | done (uncommitted) | `Context.startLive`/`stopLive` (no-op defaults); start after `beginFlight` and for retarget adds within the cap; one `stopLive` in `clear()` when anything is live; RED: compile failure (extra arguments); GREEN: 13 new tests, SnapshotFlightTests 95, 0 failures |
| LL-05 | S1-S5 | inline | done (uncommitted), verified | `SessionHost`: lazy `LiveWindowStreamer`, `startLive`/`stopLive` closures (stop also clears the overlay's live layers), `deliverLiveFrames`; `LiveWindowStreamer.deliverFrames(to:)` (handler set after creation, under its lock); `main.swift`: frames and `clearLive` hop to main; `docs/TESTING.md` log recipes (LL lines, SM-35 `snapshot stale move`). `swift test` 3292 tests, 53 skipped, 0 failures; signed `xcodebuild` BUILD SUCCEEDED; `git diff --check` clean |
| LL-06 | S1, S5 | user, live | done (first pass) | user: "it looks very fast now, quite fast :0, not that long on the past anymore"; log: 18 flights, 58 streams, 0 failures; first frame min 54 / p50 186 / p90 327 / max 458 ms; flight fps p50 86, min 60 (before: ~115-120) |

## Log

- L1 (2026-11-01, user, verbatim): "Still very back in time, why not something more inmediate?, I mean I'm
  testing with a youtube video and it just gets there" then "go with live layers".
- L2: context: SM-35 (`odd/tasks/snapshot-motion.md`) made stale moving layers re-capture mid-flight and the
  shown strip refresh past 30 s; live log 2026-11-01 07:11 UTC showed flights with 15-25 s old images (under
  the soft age) and a still frame of a playing video. No `SCStream` exists in the repo yet.
- L3: route evidence: LL-02, LL-03 and LL-04 are independent units with disjoint edit surfaces (GioMacOS,
  GioUI, GioSession), each well over 100 changed lines, launched together (Writer trigger, parallelism); the
  parent defines the seam (LL-01 and the APIs below) and owns `SessionHost.swift`, `main.swift` and git.
- L4: seam. Session to host: `SnapshotFlightController.Context.startLive(_ windows: [WindowID: CGRect])`
  (target frames, called on the session queue) and `stopLive()`. Host to streamer:
  `LiveWindowStreamer.start(_:displays:primaryDisplayHeight:)` / `stopAll()`. Streamer to overlay (main
  thread, no token): `SnapshotOverlayController.showLive(_ id: WindowID, surface: IOSurface, size: CGSize)`
  and `clearLive()`; a frame for a window without a layer is dropped.
- L5: open risk: `SCStream` start-to-first-frame latency is unknown; if live (LL-06) it lands late in the
  flight, a follow-up decides whether to keep streams warm before the press.
- L6 (2026-11-01): LL-02, LL-03, LL-04 returned green; seam check `swift test` 3292, 0 failures; writers stayed in
  their surfaces. Writer notes kept open: a live window that a retarget turns into a resize keeps streaming at its
  old size (stop is all-or-nothing); the IOSurface is shown without a use-count bump (Apple's sample does the
  same; watch for tearing live); `frames` runs under the streamer lock, so the handler only hops to main.
  Risk: item 4 (concurrency: capture queue, lock, main hop): independent verifier launched at the feature's end.
- L7 (2026-11-01): independent verifier: S4 met, S1/S5 need the live check, one blocker (S2/S3): a retarget that
  resizes an already-live window kept its live layer on top of the new-size face (stretched stream, SM-30 image
  hidden). Correction batch: `Context.stopLiveWindows` + `stopResizedLive` (retarget, before `streamLive`),
  `LiveWindowStreamer.stop(_:)`, `clearLive(_:)` per window in the overlay; advisory 1 applied: `stopLive` no
  longer clears live layers before the overlay ends (no frame of the stale image at the hand-off). RED: compile
  failures; GREEN: `testARetargetThatResizesALiveWindowStopsOnlyThatStream`,
  `testClearLiveOfOneWindowKeepsTheOtherWindowsLive`; `swift test` 3294, 53 skipped, 0 failures; signed
  `xcodebuild` BUILD SUCCEEDED. Recheck of the blocker pending.
- L8 (2026-11-01): recheck: blocker fixed (`stopResizedLive` before `streamLive`; `stop(_:)` drops under the lock
  and halts outside it; main runs the retarget, queued frames, then `clearLive(ids)`); advisory 1 change leaves no
  live layer behind on any exit (`end`, `fadeOut(keeping:)` and a new `begin` remove window layers). Advisory
  kept open: `stop(_:)` does not bump the generation, so a window stopped and restarted within one flight could
  count its old stream's frames; unreachable today (a resized live window is neither a retarget add nor a moving
  see-through layer). Next: LL-06 live check by the user, then commit on approval.
- L9 (2026-11-01, user, verbatim): "Dam, it looks very fast now, quite fast :0, not that long on the past anymore :0".
  Log of that session: first live frame p50 186 ms (the cached image shows for about half of a ~400 ms flight),
  and flight fps fell to p50 86 / min 60 from ~115-120 before live layers (4 full-resolution 60 fps streams).
  Open: tune the stream cost (half resolution, 30 fps, fewer streams) and the first-frame delay; decision pending.
