# Window rules: titles, sizes, display and focus

## Objective
Let `[[window-rules]]` say more than "this app floats / goes to workspace N": match window
titles, choose how the new window's column opens (width, maximized, width limits), on which
display, and whether it takes focus. Everything editable from Settings > Rules, never only in
`config.toml`.

## Problem (code check 2026-10-08, HEAD `5dc3dbd`)
- `WindowRule` had `app`, `bundle-id`, `mode`, `workspace`, `open-on-workspace`, `follow`.
  Rules matched the app only (`WindowRule.matches(app:bundleID:)`), so "float Safari's Picture in
  Picture but tile its browser windows" was impossible.
- New columns always opened at the layout default width and always took the strip's focus
  (`DiscoveryService.appendColumn(focus:)`); a rule could not pick a display.
- `docs/TESTING.md` Known limitations said rules match the app name only.

## Scope
WR-01..WR-06 below. Not in scope: re-evaluating rules on every title change, regex flags beyond
inline `(?...)`, TOML escape sequences in strings (the parser keeps strings verbatim).

## Constraints
- `GioCore` stays pure: matching, placement, re-check and layout clamping are Core functions;
  `DiscoveryService` and `WindowEventRouter` only call them.
- Titles are compared in memory only: no log line or error message carries a window title (a
  config error may quote the regex pattern, which is user config).
- Only keyboard/IPC actions focus: a rule never adds a focus intent; the title re-check never
  focuses or follows.
- Only `WindowReconciler` writes frames: rules change model state; the next reflow lays it out.
- First matching rule still wins entirely; config writes keep the patcher approach
  (`renderRule`, block replace).

## Decisions
- **`title`** is an `NSRegularExpression` searched in the title (`firstMatch`), case-insensitive
  by default; `(?-i)` opts out, `^...$` anchors the whole title. With `app`/`bundle-id` it is an
  AND; alone it matches any app. Nil or empty title never matches a title rule. Equality is the
  pattern text (`TitlePattern`). The parser keeps strings verbatim, so `\d` is `\d`; a `"` cannot
  be written (form validation says so). An invalid or empty pattern is a config error.
- **When rules are evaluated:** at registration (first appearance, startup scan included), as
  before. **Empty-title re-check (decided, tested):** an arrival registered with an empty title,
  while some rule has a `title`, is armed in `TitleRecheckBook`; the first `AXTitleChanged`
  with a non-empty title within **1 s** re-evaluates once (it disarms either way). Only when a
  title rule now wins (`titleRecheckOutcome`; non-title rules matched the same way before, title
  rules could not match the empty title) `applyTitleRecheck` sets the mode (rule float / back to
  tiled; admission floats untouched), width limits, and the column: moved to the rule's
  workspace/display as a new unfocused column, else reshaped in place (width, maximized) when it
  is alone in its column. Never focus, never follow, never a workspace switch. Log:
  `window rule recheck id=P:E reason=titleArrived`. Later title changes are not re-checked.
- **`default-column-width`**: same semantics as the layout key (`ruleColumnWidth`: ≤ 1
  `.proportion`, else `.points`), set on the arrival column.
- **`open-maximized`**: exactly the `maximize-column` state: `.proportion(1)` with the rule width
  (or `.standard`) in `savedWidthSpec`, so `Alt+F` restores it.
- **`open-on-display`**: numbered like `[[workspace]] display` (`WorkspaceManager.display(numbered:)`,
  now shared by `resolveDisplay`): 1 = main display, then position order. Destination: the rule's
  named workspace only if it lives on that display, else that display's stack index
  (`workspace = N`), else its shown workspace. A display that is not connected falls back to the
  existing logic (focused display / current workspace). The focused display never changes.
- **`open-focused = false`**: the column joins without becoming the workspace's focused window
  (`arrivalTakesFocus`), and the follow decision is `.stay` (no follow, no focus intent). The app
  may still activate its own window; Gio's focus adoption then follows the OS as for any click
  (documented, not fought).
- **`min-width` / `max-width`**: points (> 1, so they never read like fractions; min ≤ max). They
  ride on the window (`ManagedWindow.widthLimits`) and the layout engine
  (`ScrollableLayoutEngine(widthLimits:)`) clamps the column (stacked: largest min, smallest max;
  min capped to the usable viewport; min wins a conflict), then the learned minimum (FI-02) still
  applies, so the app's own minimum wins. `SessionHost.engine()` builds the map only when a rule
  sets limits.
- **Reload, per key:** title — float rules re-evaluated on the current title (existing float
  semantics); `min-width`/`max-width` — re-applied (`RuleReevaluation.widthLimits`, a
  constraint, not a placement); `default-column-width`, `open-maximized`, `open-on-display`,
  `open-focused`, workspace — not re-applied (arrival only, existing semantics).
- **Workspaces section** ignores `title` rules (they are narrower than "the app's windows"):
  never listed as a card app, never matched, never removed by unassigning; an unassigned app
  rule that still has other opinions (mode, width, maximized, display, focus, limits) keeps them.
- **UI:** Rules rows show app (bundle id, or "Any app"), the pattern as a subtitle and badges for
  every key; the editor sets every key with `RuleForm.problems` (same validators as the parser:
  `TitlePattern`, `ruleColumnWidth`, `isValidRuleWidthLimit`). Display picker only with more than
  one display or when the rule already has one.

## Tasks
- [ ] WR-01 (`e564c8d`) — `title` matcher (`TitlePattern`, AND with app/bundle-id, title-only
  rules) and the one empty-title re-check (`TitleRecheckBook`, `titleRecheckOutcome`,
  `applyTitleRecheck`, `DiscoveryService.titleChanged` from `WindowEventRouter`).
- [ ] WR-02 (`e564c8d`) — Parser for every new key (`buildRule`), patcher rendering
  (`renderRule`, title-only rules write no `app`), template comment block.
- [ ] WR-03 (`e564c8d`) — `default-column-width` and `open-maximized` shape the arrival column
  (`placeArrival`, also used by the pure `placeWindow` pipeline).
- [ ] WR-04 (`e564c8d`) — `open-on-display` (`display(numbered:)`, `ruleDestination`) and
  `open-focused` (`arrivalTakesFocus`, no follow).
- [ ] WR-05 (`e564c8d`) — `min-width` / `max-width` (`ColumnWidthLimits`, engine clamp, reload
  refresh).
- [ ] WR-06 (`e564c8d`) — Settings > Rules: rows and editor for every key, form round trips;
  Workspaces section leaves title rules alone.

## Evidence
- RED (2026-10-08): new tests written first — `WindowRuleTitleTests`, `WindowRuleConfigTests`,
  `RulePlacementTests`, `WindowRuleFormTests` (GioCoreTests), `RichRuleArrivalTests`
  (GioSessionTests), `RulePresentationTests` (GioUITests); `swift build --build-tests` failed to
  compile (`cannot find 'TitlePattern' in scope`, `cannot find 'ColumnWidthLimits'`, `extra
  argument 'title' in call`, `RuleOutcome has no member 'openFocused'`, `RuleRowPresentation has
  no member 'optionBadges'`, ...). After the first implementation pass,
  `testRecheckMovesTheWindowWithoutFocus` failed (the window vanished: updating the source
  re-created the trailing spare, so the destination id was stale; fixed by resolving the
  destination again) and two parser tests had a double-escaped regex literal in the test itself.
- GREEN (2026-10-08, shared working tree with the parallel NC/updater work): new suites
  WindowRuleTitleTests 11, WindowRuleConfigTests 10, RulePlacementTests 21, WindowRuleFormTests 9,
  RichRuleArrivalTests 9, RulePresentationTests 8, all 0 failures. Full `swift test`: GioUITests
  283 (53 skipped snapshot tests), GioSessionTests 384, GioPOCTests 7, GioMacTests 19,
  GioMacOSTests 50, GioCoreTests 1628, every bundle 0 failures. `git diff --check` clean.
- Signed build: parent runs `xcodebuild` (GioUI, GioSession, GioDesktop changed).
- LIVE PENDING: TESTING.md row 8b (title rule on Safari PiP, Mail on display 2 unfocused with
  limits, Chrome Meet window re-check, invalid pattern error, no title in `gio.log`). Whether the
  re-check lands for Chrome in practice (title within 1 s) is not verified live.

## Acceptance criteria
- Parser accepts/rejects every new key with line-numbered errors; invalid regex quotes the
  pattern; title-only rules valid.
- Matching: title AND app, title only, case-insensitive, no title → no match.
- Placement: width, maximized, display, not focused, min/max clamp; re-check once within 1 s,
  never focusing.
- Rules UI edits every key with the file's validation; form and config text round-trip.
- Full `swift test` 0 failures; docs (USER_GUIDE, TESTING, ARCHITECTURE, CONTRIBUTING) updated.

## Applicable checks
Strict TDD; `swift test` (all bundles), `git diff --check`; signed `xcodebuild` by the parent.

## Delivery
One work-unit commit per task is the norm; WR-01..WR-06 share types (`WindowRule`,
`RuleOutcome`, `RuleForm`) and were built together, so a single `feat(rules): ...` commit (or a
docs-separated pair) is the practical split. Not committed by this task.

## Progress
- 2026-10-08: WR-01..WR-06 implemented, tested and documented (USER_GUIDE window rules table and
  Rules row, TESTING live row 8b + log line + Known limitations fix, ARCHITECTURE registration
  step, CONTRIBUTING rule recipe, config template); uncommitted; live checks pending.
- 2026-10-09: WR-01..WR-06 committed as `e564c8d` and pushed to `main`. LIVE PENDING.
