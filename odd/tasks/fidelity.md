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
- [ ] FI-01 — Failure visibility: every reconcile failure logs id, app, kind, requested and
  actual frame (warn once per window+kind, debug afterwards).
- [ ] FI-02 — Learned minimum sizes: a size clamp (actual > requested, same position) records
  a per-window minimum; layout uses it (column width >= widest member's min width, stacked
  heights respect min heights); no retry storm; forgotten when the window is re-registered.
- [ ] FI-03 — Overlap-free motion: animate position only; apply size changes once (shrinking
  windows at the start, growing windows at the end) so neighbours never overlap mid-motion.

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
