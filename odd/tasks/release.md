# Release pipeline: versioned, signed DMG releases on GitHub

## Objective
Ship Gio as a versioned, signed DMG attached to a GitHub release of `ismaelosuna7824/gio`,
built by GitHub Actions from a tag, so the app can find, download, install and relaunch a new
version by itself (in-app updater, UP-xx below).

## Problem
- The version was a hard-coded `gioVersion = "0.1.0-alpha"` in GioCore while the app's
  Info.plist said `1.0`: two sources that disagreed.
- No release artifact, no tag, no workflow: `gio update` could only say updates are not published.
- Accessibility and Screen Recording grants are tied to the code signature's designated
  requirement (DR); an ad-hoc signed download would lose them on every update.

## Why
User decisions 2026-10-08: no Apple Developer Program license (no notarization); releases live
in the same GitHub repo (private now, public later); sign with the user's `Apple Development`
identity so the DR is stable; GitHub Actions builds on a tag; the app updates itself.

## Scope
RL-01..RL-04 below, the security-review hardening RL-05..RL-08 and UP-12..UP-17. The in-app updater is a
separate section (UP-xx).

## Constraints
- GioCore stays pure (the version decision is a pure function over an Info.plist dictionary).
- Never edit signing in `project.pbxproj`; signing comes from `Config/*.xcconfig` or CI overrides.
- Never put a real certificate, password or token in the repo; never echo secrets in CI.
- Never push tags or create releases from an agent session.

## Tasks
- [ ] RL-01 (`e564c8d`) — One version source: `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`/`GIO_UPDATE_REPOSITORY`
  (`Config/Version.xcconfig`, project-level base configuration) feed Info.plist `CFBundleShortVersionString`,
  `CFBundleVersion`, `GioUpdateRepository`. GioCore: `gioVersion` reads the bundle through the pure
  `resolveGioVersion(infoDictionary:)`, falling back to `gioBuildVersion = "0.0.0-dev"`; `isDevBuildVersion`.
  Build phase "Stamp dev version" (`scripts/stamp-dev-version.sh`) turns a default dev build into
  `<last v* tag>+dev`. Callers updated (MainWindow, DiagnosticsView; `appVersionLabel` removed), README.
- [ ] RL-02 (`e564c8d`) — `scripts/make-dmg.sh`: signature check (prints team, optional `GIO_EXPECTED_TEAM`),
  bundle version must equal the argument, UDZO HFS+ DMG (`Gio <version>`, app plus `Applications` link),
  `hdiutil verify`, `.sha256`.
- [ ] RL-03 (`e564c8d`) — `.github/workflows/release.yml`: `v*` tag (publish) or `workflow_dispatch` version
  (dry run, artifact only); latest stable Xcode on macos-15; `swift test` before signing; temporary keychain
  from three secrets plus Apple WWDR G3; Manual Apple Development signing, team `2CAK428VHF`, no profile,
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`; `gh release create --verify-tag` with tag-annotation notes or
  `--generate-notes`, `--prerelease` when the version has `-`; keychain deleted in an `always()` step.
- [ ] RL-04 (`e564c8d`) — `docs/RELEASING.md` (secrets, cutting a release, dry run, first-run Gatekeeper,
  renewal and DR verified vs inferred, public repo), AGENTS.md map/pitfall/decision rows.

Decisions:
- Team id is `2CAK428VHF` (certificate `OU`); `DPYR37JY5V` is the developer identifier inside the CN
  (`Apple Development: ismaelosuna.ca@gmail.com (DPYR37JY5V)`). Verified with `openssl x509 -subject`.
- Version settings live in a new project-level xcconfig rather than `Signing.xcconfig`, so no signing file
  changes; the target's `Signing.local.xcconfig` can still override them, and CI overrides on the command line.
- "Last tag" for local builds is stamped by a build phase (Xcode build settings cannot run git); dev builds get
  `+dev` build metadata so semver precedence equals the tag and the updater can tell dev from release
  (`isDevBuildVersion`). `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the target so the phase can read `.git`.
- Release builds pass `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`: Apple Development signing otherwise injects
  `com.apple.security.get-task-allow` even in Release (observed).
- No provisioning profile: the target has no entitlements file (`CODE_SIGN_ENTITLEMENTS` unset), no App
  Sandbox and no restricted capability; manual Apple Development signing without a profile succeeded locally.
- Apple silicon only (`ARCHS = arm64` in the target), as before.
- `hdiutil create/attach/detach` print a deprecation warning on macOS 27 (prefer `diskutil image`); kept
  `hdiutil` because the CI runner is macOS 15 and the commands still work on 27.

## Evidence
RL-01 (TDD; the shared tree had sibling agents' in-progress RED tests, so RED/GREEN ran on an isolated
`git archive HEAD` copy at /tmp/gio-rl plus these changes):
- RED: `GioVersionTests` compile failure, `cannot find 'resolveGioVersion' in scope` / `'gioBuildVersion'`;
  second cycle `cannot find 'isDevBuildVersion' in scope`.
- GREEN: `swift test --filter GioCoreTests.GioVersionTests` Executed 9 tests, 0 failures; with
  `DoctorSetupTests` 14 tests, 0 failures.

RL-01..RL-03 local dry run (2026-10-08, Xcode 27.0, /tmp copy, nothing published, no tag created):
- Debug, `MARKETING_VERSION=0.2.0-rc.1 CURRENT_PROJECT_VERSION=42`, Manual Apple Development, team
  `2CAK428VHF`, empty profile: BUILD SUCCEEDED; built Info.plist `CFBundleShortVersionString = 0.2.0-rc.1`,
  `CFBundleVersion = 42`, `GioUpdateRepository = ismaelosuna7824/gio`; `TeamIdentifier=2CAK428VHF`.
- Release, same settings plus `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`: BUILD SUCCEEDED, no entitlements,
  `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement. Without the flag the
  Release build carried `get-task-allow = true`.
- DR: `identifier "dev.gio.windowmanager" and anchor apple generic and certificate leaf[subject.CN] = "Apple
  Development: ismaelosuna.ca@gmail.com (DPYR37JY5V)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */`.
- Default dev build (no version override, no tags): `CFBundleShortVersionString = 0.0.0-dev`, `CFBundleVersion = 0`.
  Clean-build log order: ProcessInfoPlistFile, PhaseScriptExecution Stamp dev version, CodeSign.
  The tag path of `stamp-dev-version.sh` was run directly with a stub `git` printing `v0.3.0` on a copy of
  the built Info.plist: `0.3.0+dev`; with `MARKETING_VERSION=1.0.0` it is a no-op (exit 0). Not exercised
  inside an Xcode build with a real tag (no tags exist; Xcode replaces `PATH` so the stub is not used).
- `scripts/make-dmg.sh <Release Gio.app> 0.2.0-rc.1 /tmp/gio-dmg-out` with `GIO_EXPECTED_TEAM=2CAK428VHF`: exit 0,
  team 2CAK428VHF printed, `hdiutil verify` VALID, `Gio-0.2.0-rc.1.dmg` 5,695,973 bytes,
  `shasum -a 256 -c` OK. Mounted read-only: `Applications -> /Applications` and `Gio.app`, volume
  `Gio 0.2.0-rc.1`, HFS+, app inside verifies and satisfies its DR, version 0.2.0-rc.1; detached and deleted.
  Negative: version mismatch exit 65, wrong expected team exit 65 (no output written), `v0.2.0` exit 64, no
  arguments exit 64.
- `bash -n` OK for both scripts; shellcheck not installed. actionlint v1.7.12 (run via `go run`): `release.yml`
  and `ci.yml` clean (exit 0; actionlint's shellcheck pass skipped since shellcheck is absent).
- `codesign --verify -R='<DR text>' Gio.app` exit 0; a different CN exit 3 (the renewal check in RELEASING).
- Full `swift test`, isolated copy (HEAD plus these changes): GioUITests 274 (53 skipped), GioSessionTests 371,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 50, GioCoreTests 1504; 0 failures each.
- Full `swift test`, shared tree (with sibling agents' work at 16:33): GioUITests 283 (53 skipped), GioSessionTests 384,
  GioPOCTests 7, GioMacTests 19, GioMacOSTests 68, GioCoreTests 1628; 0 failures each. `git diff --check` clean.
- Signed build of the shared tree (AGENTS command, `Signing.local.xcconfig`, `.build/GioAutoTeam`): BUILD SUCCEEDED,
  inside the git repo (no tags) the stamp phase is a no-op: `0.0.0-dev`, build `0`, `GioUpdateRepository` set,
  `TeamIdentifier=2CAK428VHF`.

## Release hardening (RL-05..RL-08, security review 2026-10-08)
A security review of the updater and the release workflow (`agent://UpdaterSecurity`, findings 0..7) found no
critical or high issue; every finding below was checked against the code before fixing.

- [ ] RL-05 (`e564c8d`, finding 0 `GIO-REL-HARDENED-RUNTIME`) — Release builds are signed with the Hardened
  Runtime: `ENABLE_HARDENED_RUNTIME = YES` on the `Gio` target's **Release** configuration (not identity/team,
  so allowed in the pbxproj) and `ENABLE_HARDENED_RUNTIME=YES` in the release `xcodebuild`; `make-dmg.sh` fails
  unless `codesign -dv` shows `flags=0x...(runtime)` and unless the app has an Apple-issued identity (no ad hoc).
  Cause verified: no `ENABLE_HARDENED_RUNTIME` anywhere in the project or `Config/`, and the earlier dry-run
  build showed no runtime flag.
- [ ] RL-06 (`e564c8d`, finding 1 `GIO-REL-SIGNING-KEY-EXPOSURE`) — `release.yml`: every action pinned to a
  full commit SHA with the version in a comment (checkout v7.0.1, upload-artifact v7.0.2, download-artifact
  v8.0.2; `ci.yml` checkout v7.0.1 and cache v6.1.0; tags resolved with `git ls-remote` and the GitHub API,
  all lightweight tags on commits); `maxim-lobanov/setup-xcode` replaced by `sudo xcode-select -s` of the
  newest stable `/Applications/Xcode_<version>.app`; workflow `permissions: contents: read`; jobs **test**
  (no secrets, `persist-credentials: false`) → **build** (environment `release`, the only job with the
  signing secrets; `if: push || ref == refs/heads/main`, so a dispatch from another branch never signs) →
  **publish** (`contents: write`, ubuntu, no checkout: downloads the artifact, `sha256sum -c`,
  `gh release create --repo`). Release notes are taken from the tag annotation in the build job and travel
  in the artifact. `docs/RELEASING.md`: how to create the `release` environment (required reviewer,
  `v*` tag rule, `main` for dry runs), move the secrets there (`gh secret set --env release`), the tag ruleset,
  and a leaked-key response. The environment itself is configured by the user on GitHub.
- [ ] RL-07 (`e564c8d`, finding 5 `GIO-UPD-PREMOUNT-TRUST`, release side) — `make-dmg.sh` signs the DMG with
  the app's signing identity (`GIO_KEYCHAIN` when set) and verifies it with
  `codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "<team>" and
  certificate leaf[subject.CN] = "<authority>"'` before `hdiutil verify` and the checksum.
- [ ] RL-08 (`e564c8d`, finding 7 `GIO-REL-DISPATCH-INPUT-VALIDATION`) — the version step moved to
  `scripts/release-version.sh`: whole-string bash `[[ =~ ]]`, the tag must be `v<version>`, unknown events
  refused, `::error::` messages never contain the input. `scripts/test-release-version.sh` (12 cases).
- [x] RL-09 (`f804a21`, `c7cec18`, `9077836`) — CI had never passed (31 failures, 1 cancelled, oldest
  2026-09-30): `macos-15`'s default Xcode 16.4 / Swift 6.1 does not compile the sources (NSWindow main-actor
  isolation in `ManagedSpaceMonitor`, a type-check timeout in `KeyNames`) and cannot build the Icon Composer
  icon, so no release could have run either. CI and release.yml's macOS jobs now run on the `xcode-27` image
  (arm64, macOS 27; Xcode 27.2, Swift 6.4 on the runner) with its newest stable `Xcode_<version>.app` (or the
  default), cache key `spm-xcode27-`. CI runs `swift test` serially like release.yml: under `--parallel`
  three timing tests failed on the runner (fixed: `MotionWriteTests` gates the in-flight write instead of a
  50 ms sleep; `LauncherPanelAnimationTests` targets a frame inside the main screen, AppKit had moved a panel
  taller than the runner's virtual screen; `WriteLaneTests` slow app 0.15 s under the 0.25 s stall). Publish
  also uploads `Gio.dmg` (same file, fixed name) so `releases/latest/download/Gio.dmg` is a stable download
  link (landing `d21f1b5`); the updater still reads only `Gio-<version>.dmg` + `.sha256`. User decision
  (2026-10-15): make `ismaelosuna7824/gio` public so the landing download and the updater work without a
  token (history scanned for tokens/keys/p12 before: none). Evidence: CI run 38686821669 green (UI 310 (53
  skipped) / Session 477 / POC 7 / Mac 19 / MacOS 95 / Core 1970, unsigned app build OK); local `swift test
  --parallel` 2878 tests exit 0; local release dry run (Release, Hardened Runtime, Apple Development, team
  `2CAK428VHF`, `MARKETING_VERSION=0.1.0-rc.1`) BUILD SUCCEEDED and `make-dmg.sh` wrote and verified
  `Gio-0.1.0-rc.1.dmg`. Not run: release.yml on GitHub (needs the `release` environment and secrets).
- [x] RL-10 (tag `v0.1.0` on `40fc581`) — First release, done from the agent session at the user's request
  (2026-10-15): repo made public (`gh repo edit --visibility public`); `release` environment created by API
  (required reviewer: the maintainer, deployment policies tag `v*` and branch `main`); the three secrets set
  in the environment from the login keychain's identities exported once (the user approved the keychain
  prompt) and repacked with only the `Apple Development: ismaelosuna.ca@gmail.com (DPYR37JY5V)` cert + key
  (a `CN=localhost` identity was left out), checked by importing into a throwaway keychain (1 valid
  identity); the temp files were removed and no repository secret exists. Run 38687876209: test, build
  (approved by API), publish all green. Verified anonymously: the API lists v0.1.0 (not prerelease) with
  `Gio-0.1.0.dmg`, `.sha256`, `Gio.dmg`; `releases/latest/download/Gio.dmg` downloads and matches the
  checksum; the DMG's signature verifies; the app inside verifies (`--deep --strict`), `flags=0x10000(runtime)`,
  team `2CAK428VHF`, version 0.1.0, `GioUpdateRepository` `ismaelosuna7824/gio`, `Gio_GioUI.bundle` present.
  LIVE PENDING: Gatekeeper's Open Anyway, permissions and the first in-app update (needs a later release).
- [x] RL-11 (`7a4c8a8`, `94bc596`, `90099f7`) — After RL-09 the hosted runner still missed real-time budgets
  now and then (`WriteLaneTests` 0.15/0.12 s writes past the 0.25 s stall; `MotionLaneTests` final pass 0.257 s
  against a 0.25 s bound). Lane tests that are not about the stall use a 1 s stall (`patientReconciler`); the
  stall, claim-wait and landing-bound tests keep 0.25 s. `scripts/swift-test-ci.sh` (ci.yml and release.yml's
  test job): serial `swift test`, each failed case retried once alone, a pass on retry is a `::warning::`;
  two failures, more than three failed cases, or no failed case (build error, crash) fail. Smoke: a fake
  `swift` that fails one case then passes it exits 0 with the warning; one that fails to compile exits 1.
  CI run 38689662595 green (no retry needed).
- [ ] RL-12 (`bb2049b`, notes range in the follow-up commit) — Automatic releases (user, 2026-10-15): `dev` is
  the default branch; every merge to `main` releases and bumps the version; an action picks the bump (patch,
  minor, major). Prepare Release (`prepare-release.yml`, dispatch on `dev`, input `bump`) opens or updates the
  PR `dev` → `main` titled `Release v<next>` with the label `release:<bump>` and a body listing the commits
  since the latest release (the release notes). `release.yml` now runs on push to `main` (no tag trigger):
  job **version** reads the latest stable tag, the merged PR (`commits/<sha>/pulls`) and its single
  `release:*` label (none = patch, two = refused), then `release-version.sh` computes the version; publish
  creates the tag with `gh release create --target <sha>` and the PR body as notes. `release-version.sh`: push
  on `main` + `LATEST_TAG` + `BUMP` + `HEAD_TAGS` (refuses another branch, unknown bump, malformed tag, an
  already released commit); dispatch dry run kept; the tag-push path removed. User decision: the only human
  gate is the PR merge. GitHub set by API: `dev` created from `main` (`7d6b902`) and made default; Actions may
  create PRs; `release` environment without reviewers, deployment policy `main` only (the `v*` tag policy
  deleted); ruleset 25141017 `main: releases only` (PR required, 0 approvals, merge commits only,
  `test-and-build` required, no force push or deletion, no bypass). RED: `scripts/test-release-version.sh` 6
  new bump cases failed; GREEN 19/19. `actionlint` (`.github/actionlint.yaml` for the `xcode-27` label) clean;
  jq selectors checked on sample API JSON. Live: Prepare Release patch opened PR #7 `Release v0.1.1`
  [`release:patch`]; minor retitled it `Release v0.2.0` [`release:minor`], patch back to `v0.1.1`. The PR's
  CI missed three more lane timing budgets on the runner (fixed in `eecc436`: bound = the 0.3 s wait it guards
  against, motion release 10 ms inside the 0.1 s grace, 200 ms overlapping writes against a 1.0 s bound); then
  CI green and PR #7 `mergeStateStatus=CLEAN`. LIVE PENDING: the first merge to `main` (release.yml's version
  job, tag creation, notes from the PR).

Decisions:
- Hardened Runtime only in **Release** (pbxproj) plus the CI command line, not in Debug: Debug runs (ad-hoc or
  personal-team signing, Xcode's debug dylib, the debugger) stay exactly as before and their TCC grant is
  untouched; Debug builds are never shipped.
- No runtime exception entitlements. Checked in the source: no `dlopen`/`dlsym`/`MAP_JIT`/`DYLD_` use in the app;
  Apple Events are only *received* (`launchedAsLoginItem`), never sent. Checked on the build: no entitlements, no
  bundled dylib or framework (`otool -L` lists only system libraries). Documented: Apple's Hardened Runtime
  entitlement list has no Accessibility or Screen Recording entry (those are TCC). That AX, event taps and
  ScreenCaptureKit keep working in the hardened app is [INFERENCE], LIVE PENDING.
- Revocation: `kSecCSEnforceRevocationChecks` **not** added. Online it returned 0 for the hardened app and the
  signed DMG (UP-13 evidence), but whether a valid update is refused when ocsp.apple.com is unreachable could not
  be tested here, and an update must not fail that way; the environment and reviewer guard the key instead.
- `ditto --noextattr` kept (in addition to `--noacl --noqtn`): a copy of the hardened Release app made that way
  verifies (`--deep --strict`, DR and team requirement satisfied); only `com.apple.provenance`, which the system
  adds to new files, is present afterwards.

Hardening evidence (2026-10-08, shared tree; SwiftPM in `--scratch-path /tmp/gio-updater-build`):
- RED (tests written first): GioCoreTests failed to compile: `cannot find 'updateStagingTemplate'`,
  `'updateAsideTemplate'`, `'updateStagingDirectory'` in scope, `extra argument 'requirement' in call`; on an
  isolated copy of the reviewed tree (/tmp/gio-rev + the new tests): `cannot find
  'codeSignatureHasHardenedRuntime'`, `'updateImageRequirement'`, `'updateTokenAllowed'`, `'stagedEntryDecision'`
  in scope; with the new Core on that copy, GioMacOSTests: `cannot find type 'KeychainCalls' in scope`.
  Behavioural RED during GREEN: `testStagedCopyIsNormalisedWithoutACLsBeforeItsSecondCheck` failed because
  `ditto --noacl` kept the file ACL (fixed by removing ACLs in the tree pass).
- RED RL-08: the old step's logic extracted verbatim into `scripts/release-version.sh` failed 7 of 12 cases of
  `scripts/test-release-version.sh`; a dispatch input `0.2.0\ntag=v9.9.9` wrote `tag=v9.9.9` into
  `$GITHUB_OUTPUT` (finding 7 confirmed), and the refusal echoed the input in `::error::`. GREEN: 12/12.
- GREEN: `UpdateHardeningTests` 8, `UpdateInstallScriptTests` 10, `UpdateEligibilityTests` 10,
  `UpdateCredentialTests` 9, `UpdatePreparerTests` 17 (fresh 0700 staging folder; creation failure in a 0555
  folder refuses and detaches; image signature refused before mounting; 0777/0666 tree plus an
  `everyone allow write` ACL staged as 0755/0644 without the ACL; setuid dropped by ditto and refused by the tree
  check; real ad-hoc signed dummy apps: the helper swaps with `identifier "dev.gio.windowmanager"` and leaves no
  hidden folder, and with `identifier "com.example.other"` exits 1, restores 0.2.0, leaves nothing and logs the
  failed signature check; the real verifier refuses a dummy without the runtime flag and accepts it re-signed
  with `--options runtime`), `GitHubReleaseSourceTests` 7, `UpdateControllerTests` 13: 0 failures.
- RL-05/RL-07 local dry run (nothing published, no tag): Release `xcodebuild` with Manual Apple Development, team
  `2CAK428VHF`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES MARKETING_VERSION=0.2.0-rc.1`,
  `-derivedDataPath /tmp/gio-hardened-release`: BUILD SUCCEEDED; `flags=0x10000(runtime)`, no entitlements,
  `--deep --strict` valid, DR unchanged (`identifier "dev.gio.windowmanager" and anchor apple generic and
  certificate leaf[subject.CN] = "Apple Development: ismaelosuna.ca@gmail.com (DPYR37JY5V)" and certificate
  1[field.1.2.840.113635.100.6.2.1]`); `otool -L` lists system libraries only.
  `GIO_EXPECTED_TEAM=2CAK428VHF scripts/make-dmg.sh ... 0.2.0-rc.1 /tmp/gio-dmg-hardened`: exit 0, "hardened
  runtime: yes", DMG signed (`Identifier=Gio-0.2.0-rc.1`, `Format=disk image`, team `2CAK428VHF`), "explicit
  requirement satisfied", `hdiutil verify` checksums verified, `shasum -a 256 -c` OK. Mounted read-only:
  `Applications -> /Applications` and `Gio.app` (valid, satisfies its DR, `flags=0x10000(runtime)`, version
  0.2.0-rc.1); detached (status 0), mount point removed, DMG and checksum deleted afterwards. Negative: the same app re-signed without the runtime
  flag → exit 65 "not signed with the Hardened Runtime"; ad-hoc (`--options runtime --sign -`) → exit 65 "not
  signed with an Apple-issued identity"; no output written in either case.
- `--noextattr`: `ditto --noacl --noextattr --noqtn` of the hardened app → `codesign --verify --deep --strict`
  valid, satisfies its DR and `identifier ... and anchor apple generic and certificate leaf[subject.OU] =
  "2CAK428VHF"`.
- Updater smoke against the real signed DMG (throwaway env-gated test file, removed afterwards; nothing
  installed, the running Gio untouched): `runningAppSignature` of the hardened app read team `2CAK428VHF` and CN
  `Apple Development: ismaelosuna.ca@gmail.com (DPYR37JY5V)`; `verify(imageAt:)` success; with another CN
  `signatureRejected("disk image different developer or bundle")`; an unsigned DMG `"disk image unsigned"`;
  `verify(appAt:)` success; `SecStaticCodeCheckValidity` with `kSecCSEnforceRevocationChecks` (1 << 30) returned
  0 for both the app and the DMG (online). `UpdatePreparer` with the real `HdiutilMounter` and verifier staged
  `.../My Apps/.gio-update-KYam0X/Gio.app` (folder mode 700); the generated helper with the real requirement
  replaced a copy of the app in that temp folder: exit 0, only `Gio.app` left, log `helper started`, `gio exited;
  swapping bundles`, `installed; relaunching`; the installed copy verifies. `hdiutil info`: no leftover mount.
- `actionlint` v1.7.12 (`go run`): `release.yml` and `ci.yml` clean (exit 0; shellcheck not installed, so its pass
  is skipped). `bash -n` OK for the three scripts.
- Full `swift test` (shared tree, 17:12): GioUITests 303 (53 skipped), GioSessionTests 384, GioPOCTests 7,
  GioMacTests 19, GioMacOSTests 83, GioCoreTests 1639; 0 failures each. `git diff --check` clean (and no
  trailing whitespace in the new untracked files).
- Signed Debug build (`-derivedDataPath /tmp/gio-updater-xcode`, `Signing.local.xcconfig`): BUILD SUCCEEDED,
  `flags=0x0(none)` (Debug unchanged), team `2CAK428VHF`.

## LIVE PENDING
- First hardened release: launch, Accessibility, Screen Recording (ScreenCaptureKit), hotkeys/event taps, the
  guardian restart and the updater on a build with `flags=0x10000(runtime)`.
- The `release` environment (reviewer, `v*` rule, secrets moved) and the tag ruleset are configured by the user on
  GitHub; the three-job workflow, the SHA-pinned actions, the `xcode-select` step, DMG signing in CI and the
  publish job's artifact download have not run on GitHub yet.
- First CI release run: needs the three secrets (`APPLE_DEVELOPMENT_P12_BASE64`, `APPLE_DEVELOPMENT_P12_PASSWORD`,
  `KEYCHAIN_PASSWORD`). Not run: keychain import on the runner, WWDR download, Release signing in CI,
  `gh release create`, prerelease flag, notes from the annotation. Suggested first step: `gh workflow run
  release.yml -f version=0.2.0-rc.1` (dry run, artifact only), then a real tag.
- Gatekeeper "Open Anyway" flow for a browser-downloaded DMG, and that Accessibility/Screen Recording grants
  survive replacing the app with a newer build of the same DR: not observed live.
- Certificate renewal keeping the same CN: inference until the first renewal (certificate expires 2027-02-23).

## Progress
- 2026-10-08: RL-01..RL-04 implemented and dry-run locally (see Evidence); not committed.

## In-app updater (UP-xx)

Objective: Gio finds a newer GitHub release, downloads and verifies it, replaces itself and reopens,
and every part of that is controllable from the app (Overview, Diagnostics, menu bar) and from `gio update`.

Decisions:
- Pure decisions in GioCore (`Sources/GioCore/Update/`): semver, release JSON model, selection,
  asset pairing, checksum file, eligibility, code requirement, bundle check, state machine, cadence,
  helper script, `gio update` text. Adapters in GioMacOS (`Sources/GioMacOS/Update/`), orchestration and
  views in GioUI (`Sources/GioUI/Updates/`); GioDesktop only wires them (no new GioDesktop file).
- Cadence: one launch check 30 s after the session started (skipped within 1 h of the last check, so
  `gio restart` loops do not repeat it), then `NSBackgroundActivityScheduler` (`repeats`, interval 24 h,
  tolerance 1 h, `.utility`): the system chooses the moment and coalesces it with other work, so Gio keeps
  no timer of its own and the idle rule (PA-02) holds; a scheduled run inside `interval - tolerance` is a
  no-op. Both obey "Automatically check for updates" (UserDefaults `GioUpdateAutomaticChecks`, default on);
  Check Now and `gio update` always run unless a step is busy or an install is staged.
- Channels: prereleases only with "Include beta versions" (`GioUpdateIncludeBetas`) or when the running
  version is itself a prerelease; drafts never; dev builds (`isDevBuildVersion`: `0.0.0-dev`, `<tag>+dev`)
  are not a beta opt-in. A release without both `Gio-<v>.dmg` and `Gio-<v>.dmg.sha256` is skipped.
- Install only from `.app` bundles outside build folders (DerivedData, `.build`, `Build/Products`), not
  translocated, release (non-dev) version, team-signed, writable parent folder; otherwise notify only with
  **Open Release Page** and a reason plus "move to /Applications" suggestion.
- Signature bar: `(<running app DR>) and identifier "<bundle id>" and anchor apple generic and
  certificate leaf[subject.OU] = "<team>"`, the team read from the running app's own signature
  (`SecCodeCopySigningInformation`), never hard-coded; checked with `SecStaticCodeCheckValidity`
  (all architectures, nested code, strict) on the mounted app and again on the staged copy. Plus the new
  Info.plist must name the same bundle id and the announced version.
- GitHub: `GET /repos/<repo>/releases?per_page=30`, `If-None-Match` from the last ETag (304 reuses the
  list, no rate-limit cost); 404 without token → "private or not found", 404 with token → not found,
  401/403 with token → token rejected, 403 with `X-RateLimit-Remaining: 0` or 429 → rate limited.
  Assets: `browser_download_url` without token; with a token the API `url` with
  `Accept: application/octet-stream`, and the Authorization header is dropped on a redirect to another host.
- Token: Keychain generic password service `dev.gio.windowmanager.update-token`, account `github`;
  write-only in the UI (Save/Clear, "a token is saved"), presence checked with an attribute-only query (no
  Keychain prompt at launch), never logged.
- Install: verified app staged as `<folder>/.Gio-<v>-update.app` (same volume as the target); the helper
  (`/usr/bin/nohup /bin/sh <tmp script>`, `posix_spawn` with `POSIX_SPAWN_SETSID` and
  `POSIX_SPAWN_CLOEXEC_DEFAULT`, stdio on /dev/null) waits up to 60 s for Gio's pid and the guardian's pid,
  `mv` old aside, `mv` staged in place (fallback `ditto`), on failure restores the old app and reopens it,
  `xattr -dr com.apple.quarantine`, removes the old copy, `open <app> --args --after-restart`, deletes
  itself; logs steps and paths to `~/Library/Logs/Gio/update.log`. Gio quits through
  `NSApplication.terminate` → `applicationWillTerminate` → `SessionHost.shutdown()`, which restores windows
  and writes `clean` to the guardian (HD-07), so the guardian exits quietly instead of restoring twice.
- CLI: `CLICommand.update(install:)`; the IPC server hands `update` to the app's updater on the IPC thread
  before `queue.sync` (network never blocks the session queue); `gio update` waits for the check (45 s cap),
  `--install` replies once the download started. `dispatch(.update)` without an app explains it needs one.
- `shellQuoted` (CLIInstall.swift) became public and is shared with the helper script.

Tasks:
- [ ] UP-01 (`e564c8d`) — `SemanticVersion`: strict parse, optional `v`, build metadata ignored,
  semver 2.0 precedence incl. prerelease identifiers.
- [ ] UP-02 (`e564c8d`) — `GitHubRelease(Asset)` decoding, `updateRepository(infoDictionary:)`,
  `selectUpdate` (drafts, channels, newest), `pairUpdateAssets`, `parseChecksumFile`, `includesPrereleases`.
- [ ] UP-03 (`e564c8d`) — `installEligibility`, `updateCodeRequirement`, `checkUpdateBundle`.
- [ ] UP-04 (`e564c8d`) — `UpdateState`/`UpdateEvent`/`nextUpdateState`, `UpdateFailure` messages,
  `UpdateCadence` + `shouldCheckForUpdates`.
- [ ] UP-05 (`e564c8d`) — `updateInstallScript`, staging/aside paths, `DetachedScriptInstaller`,
  `GuardianHandle.processIdentifier`, `SessionHost.guardianPID`.
- [ ] UP-06 (`e564c8d`) — `gio update [--install]`: `CLICommand.update(install:)`, `parseUpdateRequest`,
  `describeUpdateCheck`/`describeUpdateInstall`, `SessionHost.onUpdateRequest`, launcher `describeAction`,
  usage text, `runUpdate(install:)` fallback.
- [ ] UP-07 (`e564c8d`) — `GitHubReleaseSource` over `UpdateHTTPTransport`, `KeychainTokenStore`.
- [ ] UP-08 (`e564c8d`) — `UpdatePreparer` (download, SHA-256 via CryptoKit, `hdiutil attach -nobrowse
  -readonly -noautoopen -mountpoint`, signature, bundle check, ditto staging, re-verify, detach, cleanup),
  `URLSessionAssetDownloader` (progress, redirect token strip), `HdiutilMounter`, `RequirementSignatureVerifier`,
  `runningAppSignature`.
- [ ] UP-09 (`e564c8d`) — Token UI: Diagnostics > Updates secure field, Save/Clear, never shown back.
- [ ] UP-10 (`e564c8d`) — `UpdateController` (state, toggles in UserDefaults, check/startUpdate/installAndQuit,
  `NSBackgroundActivityScheduler`, `answerCLI`), `UpdateDependencies.live`, wiring in `main.swift`.
- [ ] UP-11 (`e564c8d`) — UI: Overview **Updates** card (status, Check Now, Update and Restart with progress,
  Release Notes sheet with simple markdown via `releaseNoteBlocks`), menu bar **Update to vX.Y.Z…**,
  Diagnostics **Updates** card (automatic checks, betas, token); USER_GUIDE "Updates", TESTING rows 16/16b.

Hardening tasks (security review findings, see RL-05..RL-08 for the release side):
- [ ] UP-12 (`e564c8d`, finding 2 `GIO-UPD-STAGE-TOCTOU`) — Staging into a fresh `mkdtemp` folder
  `<parent>/.gio-update-XXXXXX` (0700) holding `Gio.app` (`updateStagingTemplate`, `makeUpdateStagingDirectory`,
  `updateStagingDirectory(ofStagedApp:)`); creation failure refuses (`stagingFailed("cannot create a private
  staging folder")`), cleanup failure is logged. The helper creates its aside folder with
  `mktemp -d <parent>/.gio-previous-XXXXXX` (refuses and reopens the old app if that fails), swaps with `mv` only
  (the `ditto` fallback is gone: same volume), then runs
  `/usr/bin/codesign --verify --strict --deep "-R=$REQ" "$TARGET"` with the shell-quoted requirement and, on
  failure, removes the new app and restores the old one before any quarantine strip or relaunch. Restores refuse
  to `mv` into an existing `$TARGET`. `DetachedScriptInstaller(requirement:)` refuses without a requirement or
  for a staged app outside a `.gio-update-` folder; a failed installer start removes the whole staging folder.
- [ ] UP-13 (`e564c8d`, finding 0, updater side; finding 1 revocation decision) — the verifier refuses a new
  app without the Hardened Runtime flag (`codeSignatureHasHardenedRuntime(kSecCodeInfoFlags)`,
  `signatureRejected("no hardened runtime")`). The requirement language cannot test signature flags, so the flag
  is checked next to `SecStaticCodeCheckValidity`. No `kSecCSEnforceRevocationChecks` (see Decisions above).
- [ ] UP-14 (`e564c8d`, finding 3 `GIO-UPD-UNSEALED-METADATA`) — staged copy made with
  `ditto --noacl --noextattr --noqtn`, then `normaliseStagedTree`: `stagedEntryDecision` (pure, GioCore) gives
  `chmod -R u+rwX,go+rX,go-w` semantics, refuses items owned by another user and setuid/setgid items, never
  chmods symlinks; every ACL is replaced by an empty one, because `ditto --noacl` keeps **file** ACLs (observed:
  `everyone allow write` survived on a file, a directory ACL was dropped). All before the second verification.
  ditto (not root) already drops setuid/setgid bits (observed); the refusal is the backstop.
  `--noextattr` decision: see Decisions above.
- [ ] UP-15 (`e564c8d`, finding 4 `GIO-UPD-KEYCHAIN-PRESQUAT`) — `KeychainTokenStore.save` = `SecItemDelete`
  then `SecItemAdd` (never `SecItemUpdate`), stops when the delete fails with anything but not-found; every query
  carries `kSecAttrSynchronizable: false`. Seam: `KeychainCalls` (`.system` in the app, a fake in tests).
- [ ] UP-16 (`e564c8d`, finding 5 `GIO-UPD-PREMOUNT-TRUST`, updater side) — before `hdiutil attach` the DMG's
  own signature must satisfy `updateImageRequirement` (`anchor apple generic` + same team OU + same leaf CN as
  the running app, no identifier clause); `RunningSignature.leafCommonName` from `kSecCodeInfoCertificates`.
  `CodeSignatureVerifying` gained `verify(imageAt:)`; `RequirementSignatureVerifier(requirement:imageRequirement:)`.
- [ ] UP-17 (`e564c8d`, finding 6 `GIO-UPD-TOKEN-HOST-ALLOWLIST`) — `updateTokenAllowed(for:)`: https,
  host `api.github.com` (any case), default port, no user info. Assets: the token goes only with an allowed API
  URL, otherwise the anonymous browser URL (`updateAssetRequest`); every redirect drops `Authorization` unless
  the new request is allowed (`updateRedirectRequest`), in the download delegate and in the release-list
  session (`URLSession.updateSession` now has an `UpdateTokenRedirectPolicy` delegate).

Evidence (2026-10-08, shared tree with sibling agents' work; builds in `--scratch-path /tmp/gio-updater-build`
to avoid fighting over `.build`):
- RED UP-01..UP-06: `swift build --build-tests` failed to compile GioCoreTests: `cannot find 'SemanticVersion'`,
  `'UpdateIneligibility'`, `'shellQuoted'` (then private), `'updateInstallScript'`, `'parseUpdateRequest'`,
  `'describeUpdateInstall'` ... in scope. GREEN: `SemanticVersionTests` 5, `UpdateSelectionTests` 10,
  `UpdateEligibilityTests` 7, `UpdateStateTests` 11, `UpdateInstallScriptTests` 6 (plus `DoctorSetupTests` 10):
  Executed 49 tests, 0 failures.
- RED UP-07/UP-08: GioMacOSTests failed to compile: `cannot find type 'GitHubReleaseSource'`,
  `'UpdateHTTPTransport'`, `'UpdatePreparer'`, `'DiskImageMounting'`, `'CodeSignatureVerifying'`;
  `'UpdateFailure' does not conform to protocol 'Error'`. GREEN: `GitHubReleaseSourceTests` 7 (ETag/304,
  bearer token, 404 without token → `repositoryUnavailable`, statuses, URLError without the token),
  `UpdatePreparerTests` 11 (checksum mismatch refuses before mounting, unreadable checksum, signature
  mismatch refuses and detaches, unsigned running app refuses before downloading, wrong bundle id/version,
  image without Gio.app, file digest; smoke: real `hdiutil create` DMG with a dummy app in a temp folder
  mounted by `HdiutilMounter` and staged; the real `RequirementSignatureVerifier` refuses the unsigned dummy;
  the generated helper script swaps bundles in a temp folder with a space in its name, removes staged/aside
  copies and itself, and logs `installed`). Executed 18 tests, 0 failures.
- RED UP-09..UP-11: GioUITests failed to compile: `cannot find type 'UpdateRowPresentation'`,
  `'updateRowPresentation'`, `'updateMenuTitle'`, `'releaseNoteBlocks'` ... GREEN: `UpdateControllerTests` 13
  (check/persisted time, up to date, private repo, betas, toggle + cadence, Update and Restart → installer with
  pids [own, guardian] → quit, checksum and signature refusals never install or quit, ineligible copy only
  notifies, installer failure does not quit, token save/clear, `gio update` and `--install` from a background
  thread), `UpdatePresentationTests` 7. Executed 20 tests, 0 failures.
- Throwaway smoke (temporary test file, removed afterwards; nothing installed, the running Gio untouched):
  the signed Debug app from `xcodebuild ... -derivedDataPath /tmp/gio-updater-xcode` read its own signature
  (`team=2CAK428VHF`, DR `identifier "dev.gio.windowmanager" and anchor apple generic and certificate
  leaf[subject.CN] = "Apple Development: ... (DPYR37JY5V)" and certificate 1[...] /* exists */`); the combined
  requirement accepted the app; team `AAAAAAAAAA` → `signatureRejected("different developer or bundle")`;
  a DMG of that app (plus `Applications` link) went through `UpdatePreparer` with the real `HdiutilMounter` and
  verifier: `success(.../Applications/.Gio-0.0.0-dev-update.app)`, the staged copy verified; after adding a
  file to its Resources: `signatureRejected("invalid signature (-67054)")`. `hdiutil info` showed no leftover mount.
- Full `swift test` (shared tree, 16:40): GioUITests 303 (53 skipped), GioSessionTests 384, GioPOCTests 7,
  GioMacTests 19, GioMacOSTests 68, GioCoreTests 1628; 0 failures each. `git diff --check` clean.
  Re-run after the attribute-only Keychain presence check: same counts, 0 failures.
- Signed build (`xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath
  /tmp/gio-updater-xcode -destination 'platform=macOS,arch=arm64' build`): BUILD SUCCEEDED (twice, last
  after the final change).

LIVE PENDING (needs a published release; see TESTING rows 16 and 16b):
- First real update end to end: check, notes sheet, download progress, quit with windows restored and
  `guardian clean exit`, helper swap, relaunch on the new version, Accessibility and Screen Recording still
  granted (DR-stable signing: inference until observed), `update.log` content, no leftovers, quarantine removed.
- `NSBackgroundActivityScheduler` firing about daily, the 30 s launch check, menu bar item, `gio update` over
  the real socket, private-repo 404 without token and download with a token (redirect token strip) against
  GitHub, `terminate` while the notes sheet was just dismissed.
- 2026-10-09: RL-01..RL-08 and UP-01..UP-17 committed as `e564c8d` and pushed to `main`. Next: the user adds the `release` environment and the three secrets, then the first `v*` tag (LIVE PENDING: first CI release, first real update).
