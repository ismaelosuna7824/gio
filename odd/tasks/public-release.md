# Public release readiness

## Objective
Get Gio ready for a first public release: what blocks it, what users will notice, and the work that
needs no decision from the owner.

## Audit (2026-10-21, three read-only audits: distribution, quality, UX)
Blockers found:
- Not notarized; signed with Apple Development, not Developer ID (`RELEASING.md:19`).
- Switching the identity breaks the updater's certificate check for existing installs
  (`UpdateEligibility.swift:93-117`).
- No LICENSE.
- No install or uninstall guide for DMG users.
- Crash restore (guardian, HD-07) and the end-to-end update never observed live.
- The recovery docs point DMG users at `gio-poc` and `gio`, which the DMG does not contain.
- The default Option shortcuts take characters on non-US layouts (Spanish ⌥1/2/3 = | @ #).
- Option+Space was hard-wired to the launcher.

Should-fix items: open issues #1–#5 (fixes in code, not verified live); Spaces with separate
displays; multi-monitor and snapshot renderer LIVE PENDING; the onboarding Screen Recording copy;
the Diagnostics config card text; no Pause; localized rule app names; release notes noise; dSYM
retention; untested macOS 13–15.

## Decisions
- Owner decides: Apple Developer Program / Developer ID + notarization (and a one-time
  reinstall note for 0.1.x users), and the license.
- Done now, with no runtime cost (user: "no debe de afectar el rendimiento"): items PR-01..PR-04.

## Tasks
- [x] PR-01 — Launcher shortcut is a normal action `toggle-launcher` (default Alt+Space), routed like
  `toggle-overview`, rebindable and removable (`"none"`) in Settings > Shortcuts and
  `[keybindings]`; `launcherHotkey` constant and `.reservedForLauncher` removed; every Shortcuts
  row editable. The launcher title bar and the menu bar item show the live combo
  (`launcherHotkey(in:)`, `menuKeyEquivalent(for:)`), read on summon / menu open only. Template:
  `toggle-launcher` documented, starter rule by `bundle-id = "com.apple.calculator"` (app names are
  localized). Routing cost: one dictionary lookup plus a switch, as before.
- [x] PR-02 — Onboarding: a keyboard-layout note in Keys to Know; Screen Recording step
  "(Recommended)" and left out below macOS 14 (`onboardingSteps(screenRecordingAvailable:)`);
  Accessibility copy "never stores or uploads window contents". Diagnostics config card: an error
  (file rejected, defaults in use, custom shortcuts included) is red and says so; warnings only
  (file applies) are yellow. `SessionFacts.configRejected` from `loadGioConfigReport`, through
  `ConfigCoordinator.status` and `SessionFactsBuilder` (cold path, once per publication).
- [x] PR-03 — Docs: README Install (DMG link, Apple silicon, macOS 13+, Open Anyway, permissions),
  Uninstall (paths and `tccutil reset`), Recovery order (quit/guardian, reopen Gio, Diagnostics >
  Restore All Windows, `gio-poc` from source), Privacy; USER_GUIDE Install, First steps, Keyboard
  layouts, Uninstall, If your windows disappear, Known limitations; CLI and `gio-poc` marked
  source-only; menu bar section matches the code; test baselines in TESTING and AGENTS.
- [x] PR-04 — Prepare Release notes drop `docs(odd)`, `test`, `ci`, `chore`, `build` subjects and
  start with an "Apple silicon, macOS 13 or later; not notarized yet" line (checked against
  `v0.1.2..HEAD`; `actionlint` clean).

Evidence: bundles UI 341 (53 skipped) / Session 550 / POC 7 / Mac 19 / MacOS 102 / Core 2110, all
0 failures; signed Debug build OK; `git diff --check` clean. RED observed for `launcherHotkey(in:)`
and `menuKeyEquivalent(for:)` (compile); the slice tests were written first but not run before the
code (no builds mid-flight). A test that pinned the keyboard note's wording was removed.
LIVE PENDING: rebinding the launcher in Settings and seeing the title bar / menu follow; the
onboarding on macOS 13 (no machine); the red/yellow config card with a broken and a warning-only
config.

## Next (owner)
1. Developer ID + notarization, then a transition release with a reinstall note.
2. License.
3. Live checks: `kill -9` restore (TESTING 12b), end-to-end update (16, 16b), Spaces with two
   displays (15d, 15e), onboarding on a fresh account (15f), then close #1–#5.
