# Tileability probe errors (2026-10-26)

## Objective
A transient Accessibility error while Gio checks whether a window can be resized must not
take the window out of the layout. Every tiled/floating change Gio makes on that check,
and every user activation that Gio drops, leaves one log line.

## Problem
User report: after a while, an Electron app (Postman, VS Code) is missing from the
Overview and keyboard focus cannot reach it.

Log evidence (`~/.config/gio/gio.log.1`, 2026-10-23): window `78102:618` (Postman) is
still registered (its snapshots succeed) but is missing from two Overview captures at
23:10:13Z and 23:10:15Z; at 23:10:22Z the session logs
`focus adopt source=activation id=78102:618 column=8 unplaced`, a workspace member with no
tiled frame, so the window was no longer tiled. No log line says why.

Mechanism (verified in code):
- `reconcileTileability` (`Sources/GioCore/Window/TileabilityCache.swift`) re-probes tiled
  windows and `floating(.notResizable)` windows through `TileabilityCache`. A false
  verdict calls `registry.setFloating(.notResizable, ...)` without a log line, and the
  verdict stays cached until a resize event, a re-registration or a resync invalidates it.
- The probe, `axIsTileable` (`Sources/GioMacOS/Accessibility/WindowDiscovery.swift`),
  returns false for ANY error from `AXUIElementIsAttributeSettable` (for example -25204
  `kAXErrorCannotComplete` from a busy Electron app, common after sleep), the same answer
  as a real "not settable". One transient error therefore floats the window for hours.
- The Overview lists only tiled windows (`SessionFactsBuilder` through `tilingWorkspace`)
  and keyboard focus walks the tiled strip, so the window disappears from both.
- `FocusCoordinator` drops some user activations without a log line (focused window
  unreadable, app not frontmost, window minimized, window work not allowed).

## Why
User report 2026-10-23/26. The window manager must not lose a window because its app was
briefly busy (AGENTS.md rule 10, absence is not death), and the log must explain any
change of a window's mode.

## Scope (authorized 2026-10-26)
Branch `fix/tileability-probe-errors` from `dev`. TP-01..TP-03 below. Committed 2026-10-26 on the user's request.

## Decisions
- The probe outcome is three-valued and Core-owned: `TileabilityProbe.tileable`,
  `.notTileable`, `.undetermined(status:)` with the AX status as a plain `Int`
  (no AX types in GioCore).
- `axTileability(_:)` (GioMacOS) returns `.undetermined` whenever
  `AXUIElementIsAttributeSettable` fails, `.notTileable` only for a successful
  "not settable" answer or `AXFullScreen = true`. `axIsTileable` keeps its Bool contract
  for the `gio-poc` tile assembly (`TileAssembly.swift`, outside this scope) and is now
  `axTileability(element) == .tileable`.
- `invalidUIElement` (-25202) is `.undetermined` too: a destroyed window is removed by its
  destroyed event, a terminated pid or a complete scan (rule 10), never by the probe.
- On `.undetermined`, `reconcileTileability` keeps the window's mode, caches no verdict
  and stores a retry deadline (`now + TileabilityCache.retryInterval`). Until the deadline
  the window is not probed again, so a busy app costs one probe per interval, not one per
  reflow. `invalidate`, `invalidateAll` and `retain` clear deadlines with verdicts, so a
  resize event re-probes at once.
- `TileabilityCache.retryInterval = 5` seconds, a `public static let` on the type that owns
  it, like `EnhancedUIGuard.stateLifetime` and `TransientWriteRetry.delays`.
- Admission at registration (`classifyWindowAdmission`) is unchanged. A registration-time
  error floats the window as `.notResizable`; the reflow re-probe covers that reason, and
  with errors no longer cached as false it promotes the window back on the first
  successful probe.
- Logging stays outside Core's decision: `reconcileTileability` returns a
  `TileabilityReconciliation` (modes, mode changes, undetermined probes), and each change
  and undetermined probe has a pure `logLine`. The session logs the changes at info
  (`window mode id=<pid:elementID> app=<name> from=tiled to=floating reason=notResizable`
  and the reverse) and the undetermined probes at debug
  (`window probe undetermined id=<pid:elementID> app=<name> axerror=<code>`, the key
  the actuator already uses for AX errors). An
  undetermined probe happens at most once per window per retry interval, so the debug
  line is rate-limited by construction.
- Activation drops in `FocusCoordinator` log one debug line each, in the existing
  `focus dropped ... reason=...` form. Not logged: Gio's own pid (expected, every Gio
  window activation) and a `focusChanged` from a background app (fires on every passive
  background key-window change and would flood the log). `allowsWindowWork() == false`
  in `requestAdoption` is logged only for sources other than `focusChanged`, for the
  same reason (a foreign Space produces a stream of them).

## Constraints
- AGENTS.md hard rules: GioCore imports no AX; only `WindowReconciler` writes frames;
  logs carry ids, codes and app names, never window titles; session state only on the
  session queue. No new code comments (user rule). Quote paths.

## TDD
Strict TDD on (AGENTS.md). Runner: `swift test`. RED (compile failure counts) before each
GREEN.

## Delivery
`ask-on-risk`; forecast under 400 authored lines in total. No commits (user rule), so the
evidence is uncommitted working-tree state; native review not run.

## Tasks
- [x] TP-01 — Three-valued probe outcome; no cached verdict and a retry deadline on
  `undetermined`. Route: delegated writer. Trigger: 2+ non-trivial files. Commit `09532d3`.
  DONE, UNCOMMITTED. `TileabilityProbe` and `TileabilityResolution` (`.retryPending` while
  a window waits for its retry) in `TileabilityCache.swift`; `TileabilityCache.resolve(_:now:
  probe:)` caches only definite answers and stores a retry deadline for `undetermined`;
  `invalidate`/`invalidateAll`/`retain` clear deadlines. `reconcileTileability` takes `now`
  and keeps the mode on `undetermined`/`retryPending`. `axTileability(_:)` (GioMacOS) is the
  three-valued probe; `axIsTileable` wraps it for `TileAssembly`. `SessionHost.tileableModes`
  passes `ProcessInfo.processInfo.systemUptime`; a window the actuator has no element for
  stays `.notTileable` (unchanged behavior, no AX call was made). Existing tests migrated
  (`FloatingManagementTests`, `MinimizeLifecycleTests`, `OverviewMoveTests`,
  `DwindleMembershipTests`). Evidence: RED compile failures (`type 'Bool' has no member
  'tileable'`, `type 'TileabilityCache' has no member 'retryInterval'`); GREEN focused
  `swift test --filter GioCoreTests.(TileabilityProbeTests|FloatingManagementTests|
  MinimizeLifecycleTests|OverviewMoveTests|DwindleMembershipTests)` 80 executed, 0 failures.
- [x] TP-02 — Log every tiled/floating change and each undetermined probe from
  `reconcileTileability`. Route: delegated writer. Trigger: 2+ non-trivial files. Commit `09532d3`.
  DONE, UNCOMMITTED. `reconcileTileability` returns `TileabilityReconciliation` (`modes`,
  `changes: [TileabilityModeChange]`, `undetermined: [UndeterminedTileabilityProbe]`), each
  with a pure `logLine`; `SessionHost.tileableModes` records changes at info and undetermined
  probes at debug and returns `modes`. Lines:
  `window mode id=10:2 app=App from=tiled to=floating reason=notResizable`,
  `window mode id=10:1 app=App from=floating to=tiled reason=resizable`,
  `window probe undetermined id=10:1 app=App axerror=-25204`. Evidence: RED compile failures
  (`value of type '[WindowID : WindowMode]' has no member 'modes'`); GREEN same focused
  filter 85 executed, 0 failures. The `GioLog.record` calls in `SessionHost` are untested
  (no host tests, AGENTS.md pitfall); the lines themselves are tested.
- [x] TP-03 — Log the activation drops in `FocusCoordinator`. Route: delegated writer.
  Trigger: 2+ non-trivial files. Commit `2177021`.
  DONE, UNCOMMITTED. Debug lines through the existing `context.log`:
  `focus dropped source=<s> pid=<pid> reason=window work not allowed` (requestAdoption,
  sources other than `focusChanged`; adoptResolved, all sources),
  `focus dropped source=<s> pid=<pid> reason=focused window unreadable` (adoptNow without
  an element), `focus dropped source=<s> pid=<pid> frontmost=<pid|none> reason=app not
  frontmost`, `focus dropped source=<s> id=<pid:elementID> reason=window minimized`. Not
  logged: Gio's own pid and a background app's `focusChanged`. Evidence: 5 new
  `FocusCoordinatorTests`; RED 4 failures (`("[]") is not equal to ...`), the fifth (nothing
  logged) passed vacuously as expected; GREEN `swift test --filter
  GioSessionTests.FocusCoordinatorTests` 44 executed, 0 failures.

## Acceptance criteria
- An erroring probe never changes a window's mode and is not cached; it is retried after
  `TileabilityCache.retryInterval`.
- A real "not settable" or fullscreen answer still floats the window as `.notResizable`
  and is cached as before; a passing probe promotes it back.
- Each mode change by `reconcileTileability` is one info line; each undetermined probe one
  debug line; no window titles.
- Each dropped user activation is one debug line, except the documented flood cases.
- `swift test` green in every bundle; signed build succeeds; `git diff --check` clean.

## Progress
TP-01..TP-03 done (`09532d3`, `2177021`). Verification 2026-10-26:
- `swift test`: one combined bundle in this toolchain (`GioPackageTests.xctest`): 3244
  executed, 53 skipped, 0 failures. Baseline sum 3227 plus 17 new tests (12
  `TileabilityProbeTests`, 5 `FocusCoordinatorTests`).
- Signed build (`xcodebuild ... -scheme Gio ... build`): BUILD SUCCEEDED.
- `git diff --check`: clean.
- Docs: `docs/ARCHITECTURE.md` floating-management paragraph; `AGENTS.md` decisions table.
- LIVE PENDING: reproduce with a busy Electron app (Postman or VS Code, for example after
  sleep). Confirming check: `gio list-windows` shows the window staying `mode=tiled`; if
  its mode changes, a `window mode id=... from=... to=... reason=...` info line explains
  it, and `window probe undetermined ... axerror=...` debug lines show transient errors.
  Not verified live: which AX status Electron apps return when busy, and whether 5 s is
  long enough between retries for them.

## Next step
User review and commit; then the live check above.
