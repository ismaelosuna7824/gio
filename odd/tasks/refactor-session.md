# Refactor: split SessionHost into a testable GioSession module

## Objective
Turn `Sources/GioDesktop/SessionHost.swift` (3260 lines, one class, no tests because the Xcode
target compiles it directly) into a thin composition root (< 800 lines) over cohesive, unit-tested
components in a new SPM library target `GioSession`, with ZERO behaviour change. Add GitHub CI.

## Problem (read-only map 2026-09-30)
25 responsibility clusters in one class; every cluster touches `performReflow` (260-line function);
hubs `session` (169 uses) and `physicalFrames` (28); ~25 hidden AppKit reads on the session queue
(NSEvent.pressedMouseButtons, NSWorkspace.frontmostApplication, NSScreen.main); 5 lock-guarded
properties; 45 `[weak self]` sites; motionTick runs at display rate. Recent bugs (own-pid crash,
tap death, zoom races, false render nudges) all lived here, untested.

## Why
User (2026-09-30): "dale con el session host" — refactor before new Niri features.

## Architecture
- New target `GioSession` (deps GioCore + GioMacOS; AppKit allowed) + `GioSessionTests`; product
  linked by the Xcode Gio target (4 minimal pbxproj entries mirroring GioUI).
- Seams: `SystemProbe` (mouse buttons/location, frontmost pid, screens, running pids, window-server
  list), `SessionScheduler` (async/asyncAfter/strict timers; sync TestScheduler), `MainHop`,
  `OverlayPort`, publication ports; components are final classes called only on the session queue
  (dispatchPrecondition), each given a small Context of closures (never the whole host).
- SessionHost keeps queue, lifecycle, IPC wiring and composition.

## Constraints
- No behaviour change: characterization tests before moving each cluster; motionTick hot path stays
  allocation-free (plain closures / final classes, no existentials, no per-tick Task); keep `.strict`
  timers; locks move with their data; own-pid guards kept with a test per entry point.
- Every step: `swift test` (all bundles) + signed `xcodebuild` green; small commits; Conventional
  Commits, NO Co-Authored-By; push after verified batches; no PR. Quote trailing-space path.
- Live behaviour cannot be proven by these tests — record what was not run live.

## Tasks
- [x] RF-00 (`49c4bfa`) — Scaffold `GioSession` + tests target + pbxproj product link; smoke test.
- [x] RF-01 (`f7c59ff`) — `SystemProbe` + `SessionScheduler` seams replacing direct AppKit reads.
- [x] RF-02 (`3ec8016`) — Publication: FocusRingPublisher, FocusDimPublisher, BarSnapshotPublisher.
- [x] RF-03 (`a03f30f`) — RenderVerifier.
- [x] RF-04 (`7a5fbf0`) — ConfigCoordinator + IPCRouter.
- [x] RF-05 (`18e7b4a`) — SnapshotFlightController + SnapshotCacheRefresher (OverlayPort).
- [x] RF-06 (`938839c`) — NativeZoomController.
- [ ] RF-07 — MotionDriver + ResizeProbeRunner (tick benchmark before/after).
- [ ] RF-08 — FocusCoordinator (adoption, settle, intent, warp, hover).
- [ ] RF-09 — WindowEventRouter + DiscoveryService.
- [ ] RF-10 — ReflowPlanner (value-returning performReflow core).
- [ ] RF-11 — ActionApplier (`apply(_:)` → ActionEffect).
- [ ] RF-12 — GitHub Actions CI: `swift test` + unsigned `xcodebuild` on macOS runner.

Evidence RF-00..03 (route: delegated writer, opus): GioSession target + product linked (4 pbxproj
entries, plutil OK); SystemProbe/LiveSystemProbe, SessionScheduler (QueueScheduler/ManualScheduler),
MainHop; FocusRingPublisher, FocusDimPublisher, GatedStatePublisher, SessionFactsBuilder;
RenderVerifier. SessionHost 3260 -> 2986 lines. GioSessionTests 47; all bundles 0 failures (parent
re-ran); signed build OK. Characterization tests mostly compile-RED only (pin current behaviour).
Notes: components built in init with [unowned self]; no dispatchPrecondition (documented contract);
snapshotCell stays in host (SessionSnapshot lives in GioUI). NOT run live.

Evidence RF-04..06 (route: delegated writer, opus): ConfigCoordinator (+dispatcher lock), IPCRouter,
SnapshotFlightController (OverlayPort, neutral OverlayFlight), SnapshotCacheRefresher (fixed latent
unlocked capture-screen read), NativeZoomController (settle poller on scheduler strict timer).
SessionHost 2986 -> 2426. GioSessionTests 92; all bundles 0 failures (parent re-ran); signed build
OK. Characterization only (no behavioural RED). NOT run live.

## Acceptance criteria
- SessionHost < 800 lines; GioSession components covered by GioSessionTests; all bundles green;
  signed build OK; docs (ARCHITECTURE, AGENTS, CONTRIBUTING) updated; CI green on push.

## Applicable checks
- TDD: STRICT ON (characterization tests first per step). Runner `swift test` (read every bundle line).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.

## Routes
Map: delegated Explore (done). RF-00..RF-12: delegated writers in batches (RF-00..03, 04..06,
07..09, 10..12), sequential.

## Progress
- 2026-09-30: map done, document created. Next: RF-00..RF-03.
- 2026-09-30: RF-00..RF-03 done, pushed. Next: RF-04..RF-06.
- 2026-09-30: RF-04..RF-06 done, pushed. Next: RF-07..RF-09.
