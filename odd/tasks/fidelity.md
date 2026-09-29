# Fidelity: minimum sizes, overlap-free motion, failure visibility

## Objective
Windows with app-enforced minimum sizes tile without overlapping neighbours or retrying
forever, and animations of stacked/resized columns never show the old composition
overlapping the new one.

## Problem (live run 2026-09-29, screenshots + ~/.config/gio/gio.log)
- WhatsApp / Xcode / Activity Monitor stay wider than their column and overlap neighbours;
  the log shows `reflow ... failed=1` on every reflow and only "see firstFailure in tile
  report" — no window id, app or requested/actual frame is logged.
- Known macOS behaviour (earlier prototype, engram "gio-ax-size-clamp-policy"): apps clamp
  to an unpublished minimum size (e.g. requested 440 -> actual 500); AX exposes no minimum.
- Stacked columns (VS Code over OrbStack): during motion the previous composition overlaps
  for a moment. MotionPlayer lerps size every frame; Electron/OrbStack repaint resizes
  slowly (`anim done ... dropped=5 slowest=OrbStack 13ms`).

## Why
User (2026-09-29): "hay windows que hacen raro el tiling ... la composicion anterior se
sobrepone por un segundo". User approved fixing these before new Niri features.

## Scope (authorized)
FI-01..FI-03. New Niri features (dynamic workspaces, overview, trackpad, focus ring,
open/close animations, tabbed columns, mouse move) are not authorized yet.

## Constraints
Pure logic in GioCore with XCTest; only WindowReconciler writes; Gio never manages its own
pid; logs carry ids/app names, never titles. Conventional Commits, NO Co-Authored-By.
Push to origin feat/gio-niri-rewrite after verified batches; no PR. Quote trailing-space path.

## Tasks
- [x] FI-01 (`22e7c6d`) — Failure visibility: every reconcile failure logs id, app, kind, requested and
  actual frame (warn once per window+kind, debug afterwards).
- [x] FI-02 (`bd7447f`) — Learned minimum sizes: a size clamp (actual > requested, same position) records
  a per-window minimum; layout uses it (column width >= widest member's min width, stacked
  heights respect min heights); no retry storm; forgotten when the window is re-registered.
- [x] FI-03 (`75c59a9`) — Overlap-free motion: animate position only; apply size changes once (shrinking
  windows at the start, growing windows at the end) so neighbours never overlap mid-motion.

Evidence (route: one delegated writer): `reconcile failure id= app= kind= requested= actual=`
(warn once per window+kind); learning rule = >1pt larger with one edge anchored (both edges
moved = position clamp, not learned), minimums only grow, column width capped to viewport,
stacked heights pin mins; motionFrame = origin eased, shrink at first frame, grow on final pass.
Prepositions keep full frame (window fully below display; accepted by parent: cannot overlap).
Overlap geometry tests are regression guards only (pure model can't reproduce app repaint lag).
Bundles 20/7/19/23/647 all 0 failures (parent re-ran); signed build OK. LIVE PENDING.
Review: UNAVAILABLE.
- [x] FI-04 (`50d82a0`) — Hotkey tap resilience (live 2026-09-29): sessions 18:07Z/18:30Z/19:39Z had zero
  `hotkey` lines. `tapCallback` ignores `.tapDisabledByTimeout`/`.tapDisabledByUserInput`, so a
  macOS-disabled tap stays dead; tap always subscribes to mouseMoved (even with
  focus-follows-mouse off); main thread may block on session queue during slow reflows (495ms
  startup reflow). Fix: re-enable + watchdog, conditional mouseMoved, no main-thread queue.sync.
  DONE: re-enable on disable events + 2s watchdog, mouseMoved only with focus-follows-mouse,
  PublishedValue snapshot cache (no main-thread queue.sync except start/shutdown), MenuBar IPC
  off-main. Bundles 20/7/19/30/649 all 0 failures (parent re-ran); signed build OK. LIVE PENDING.
  Route: delegated writer. FI-02 LIVE PASS: `min size learned` WhatsApp w=970, Figma w=900.
- [x] FI-05 (`98ca22a`) — Render verification (live 2026-09-29): user saw an empty area where windows should
  be until pressing Alt+J; log at the time: final passes `already=10` (AX reported every window at
  target). Hypothesis: WindowServer/app did not reflect the AX move (Chromium/Electron after
  unparking). Fix: ~150ms after motion settles compare AX frames with CGWindowList bounds
  (public, no Screen Recording) for visible windows; log `render mismatch id= app= ax= ws=`;
  corrective nudge rewrite; log `render nudge ... fixed=<bool>`. Route: delegated writer.
  DONE: CGWindowList layer-0 pid+bounds snapshot, two-pass matching (exact then unique same-size,
  ambiguous skipped), mismatch vs AX frame, nudge = +1pt x then target (single shot), check 150ms
  after settle, re-check 100ms; cancelled by new motion / mouse down. Bundles 22/7/19/32/728 all
  0 failures (parent re-ran); signed build OK. LIVE PENDING (user: windows were missing).
- [ ] FI-06 — Move column + immediate keyboard focus (live 2026-09-29): Alt+Shift+H/L runs
  `moveWindow(.left/.right)`, which appends the window INTO the neighbour column (stacking; OrbStack
  then clamped 366 -> 452 high). Niri moves the whole column. Rapid keys: each retarget restarted
  the full 200ms (`anim done ... duration=1142ms`) and focus intent waited for the final pass, so
  typing went to the old window. Fix: Alt+Shift+H/L = move-column-left/right (swap, composition
  kept; stacking stays on Alt+[ / ]); apply keyboard focus immediately. Route: delegated writer
  (shared with NF-04).

## Acceptance criteria
- WhatsApp/Xcode no longer overlap neighbours; `failed=` stays 0 after the first learn pass.
- Stacked-column moves show no transient overlap.
- All 5 test bundles green; signed build OK; docs updated.

## Applicable checks
- TDD: STRICT ON. Runner `swift test` (read all 5 "Executed" lines).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.
- Review: UNAVAILABLE (gentle-ai trailing-space path defect; user chose continue).

## Routes
- FI-01..FI-03: one delegated writer.

## Progress
- 2026-09-29: document created. Next: FI-01..FI-03.
- 2026-09-29: FI-01..FI-03 done, pushed. Next: user live check.
- 2026-09-29: live: shortcuts dead all session (tap disabled, never re-enabled). FI-04 done, pushed.
