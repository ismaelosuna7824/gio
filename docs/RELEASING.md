# Releasing Gio

How a Gio release is versioned, signed, built and published, and what users see when they install it. Decisions and evidence: [`odd/tasks/release.md`](../odd/tasks/release.md) (RL-01..).

Contents: [Overview](#overview) · [Versioning](#versioning) · [One-time setup: signing secrets](#one-time-setup-signing-secrets) · [Hardened Runtime](#hardened-runtime) · [Workflow security](#workflow-security) · [Cut a release](#cut-a-release) · [Dry run and local DMG](#dry-run-and-local-dmg) · [What users see](#what-users-see-the-first-time) · [Certificate renewal](#certificate-renewal-and-the-designated-requirement) · [Public repository](#public-repository) · [Troubleshooting](#troubleshooting)

**Branches.** `dev` is the default branch: all work lands there. `main` only receives release pull requests from `dev`, and every merge to `main` publishes a release.

## Overview

| Piece | What it does |
| --- | --- |
| Actions > **Prepare Release** (`.github/workflows/prepare-release.yml`) | The only thing a maintainer starts by hand, on `dev`: choose the bump, **patch** (0.1.0 → 0.1.1), **minor** (→ 0.2.0) or **major** (→ 1.0.0). It opens (or updates) the pull request `dev` → `main` titled `Release v<next>`, labeled `release:<bump>`, whose body lists the commits since the latest release and becomes the release notes. Merging it is the release. |
| `.github/workflows/release.yml` | On every push to `main` (the merge of a release pull request), four jobs: **version** (read-only: the latest stable `v*` tag, the merged pull request's `release:*` label, no label meaning patch, and its number), **test** (`swift test`, no secrets; a failure stops the release), **build** (in the `release` environment: a Release build with the Hardened Runtime signed with the **Apple Development** identity from the environment secrets, then the signed DMG, uploaded as an artifact) and **publish** (the only job with `contents: write`; downloads the artifact, checks its SHA-256 and runs `gh release create`, which creates the tag on the merged commit, with the pull request's body as notes). Releases are always stable (a prerelease version only exists as a dry run). The macOS jobs run on the `xcode-27` runner image (arm64, macOS 27) with its newest stable Xcode: older toolchains (`macos-15`'s Xcode 16.4) do not compile the sources and cannot build the Icon Composer app icon. |
| `scripts/release-version.sh` | The version step of both workflows: on a merge to `main`, the latest tag plus the bump (`patch`/`minor`/`major`) to `tag`/`version`/`publish`/`prerelease`; a dispatch input for a dry run. Refuses another branch, an unknown bump, a malformed tag or version, and a commit that already carries a `v*` tag (a re-run never publishes twice), without echoing the input. Tests: `scripts/test-release-version.sh`. |
| `scripts/make-dmg.sh` | Verifies the app signature (`codesign --verify --deep --strict`, prints the team), requires an Apple-issued identity and the Hardened Runtime flag, checks the bundle version, writes `Gio-<version>.dmg` (volume `Gio <version>`: `Gio.app` plus an `Applications` link), signs the DMG with the app's identity and verifies that signature, then writes `Gio-<version>.dmg.sha256` (`<hex>  Gio-<version>.dmg`). |
| Release assets | `Gio-<version>.dmg`, `Gio-<version>.dmg.sha256` (what the in-app updater reads), and `Gio.dmg`, the same DMG under a fixed name so `https://github.com/ismaelosuna7824/gio/releases/latest/download/Gio.dmg` always serves the newest stable release (the landing page's Download buttons). The release body is the release pull request's body, or GitHub's generated notes when it is empty. |

There is no Apple Developer Program membership, so builds are **not notarized**. They are signed with the maintainer's `Apple Development` certificate so the code signature's designated requirement stays the same across versions, which keeps the Accessibility and Screen Recording grants across updates. Builds are Apple silicon only (`ARCHS = arm64`).

## Versioning

One source: the `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` build settings.

| Key in the app's Info.plist | Build setting | Release value | Local default (`Config/Version.xcconfig`) |
| --- | --- | --- | --- |
| `CFBundleShortVersionString` | `MARKETING_VERSION` | the tag without `v` | `0.0.0-dev`, stamped `<last v* tag>+dev` when the repository has a tag |
| `CFBundleVersion` | `CURRENT_PROJECT_VERSION` | the workflow run number | `0` |
| `GioUpdateRepository` | `GIO_UPDATE_REPOSITORY` | `ismaelosuna7824/gio` | `ismaelosuna7824/gio` |

- `Config/Version.xcconfig` is the project-level base configuration; the target's `Signing.xcconfig` and your git-ignored `Signing.local.xcconfig` can override it, and `xcodebuild` command-line settings override everything (that is how CI sets the release values).
- The Xcode build phase **Stamp dev version** (`scripts/stamp-dev-version.sh`) only acts when `MARKETING_VERSION` is still `0.0.0-dev`: it writes `<last tag>+dev` (for example `0.2.0+dev`) into the built Info.plist. The `+dev` build metadata does not change semver precedence, so a dev build is never offered the release it was built after, and `isDevBuildVersion` (GioCore) recognizes it.
- In code, read `gioVersion` (GioCore): the bundle's `CFBundleShortVersionString`, else the build-time `gioBuildVersion` (`0.0.0-dev`) for SwiftPM builds such as the `gio` CLI. Never hard-code a version string.

## One-time setup: signing secrets

The workflow needs three secrets, stored in the GitHub **environment** `release` (not as repository secrets), so only the build job of a run on `main` can read them. Never commit a certificate, a `.p12`, a password or a token.

0. **Create the `release` environment** (done once; RL-10 created it by API). **Settings > Environments > New environment**, name `release`:
   - **Deployment branches and tags**: **Selected branches and tags**, only the branch `main`. Releases and dry runs both run on `main`; the workflow refuses to sign a dispatch from any other branch anyway.
   - **Required reviewers**: none (RL-12). The human gate is the merge of the release pull request: `main` accepts changes only through a pull request (see below). Add a reviewer if you want every signing run to wait for an approval as well.
   - **Protect `main`** (**Settings > Rules > Rulesets**, ruleset `main: releases only`, created by RL-12): require a pull request, allow only **merge commits** (a squash or rebase would leave `dev` and `main` with different histories), require the `test-and-build` check, block force pushes and deletion, no bypass. Nobody pushes to `main` directly, so nothing publishes without a merged pull request.

1. **Export the identity as `.p12`.** Open **Keychain Access**, select the **login** keychain and **My Certificates**. Find `Apple Development: ismaelosuna.ca@gmail.com (DPYR37JY5V)` and expand it to check a private key is underneath (without the key the export is useless). Right-click the certificate, **Export "Apple Development: ..."**, format **Personal Information Exchange (.p12)**, save it outside the repository (for example `~/Desktop/gio-signing.p12`) and set a strong export password. macOS asks for your login password to release the key.
2. **Base64 it** and store the three secrets in the `release` environment with the GitHub CLI (or **Settings > Environments > release > Environment secrets > Add secret**):

   ```sh
   base64 -i ~/Desktop/gio-signing.p12 | gh secret set APPLE_DEVELOPMENT_P12_BASE64 --env release --repo ismaelosuna7824/gio
   gh secret set APPLE_DEVELOPMENT_P12_PASSWORD --env release --repo ismaelosuna7824/gio   # prompts: the export password
   openssl rand -base64 24 | gh secret set KEYCHAIN_PASSWORD --env release --repo ismaelosuna7824/gio
   rm ~/Desktop/gio-signing.p12
   ```

   If they were stored as repository secrets before, delete those (`gh secret delete <NAME> --repo ismaelosuna7824/gio`) so no other job can read them.

   | Secret | Value |
   | --- | --- |
   | `APPLE_DEVELOPMENT_P12_BASE64` | The base64 of the `.p12` (identity: certificate plus private key). |
   | `APPLE_DEVELOPMENT_P12_PASSWORD` | The `.p12` export password. |
   | `KEYCHAIN_PASSWORD` | Any random string; it locks the temporary keychain the job creates and deletes. |

3. The workflow imports the identity (and Apple's WWDR G3 intermediate, downloaded from apple.com) into a temporary keychain, signs with `CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=2CAK428VHF`, and deletes the keychain in an `always()` step. The team is the certificate's organizational unit (`OU=2CAK428VHF`); `DPYR37JY5V` in the name is the developer identifier, not the team.

No provisioning profile is needed: the `Gio` target has no entitlements file (the Hardened Runtime needs none for Gio, see below), no App Sandbox (`ENABLE_APP_SANDBOX = NO`) and no restricted capability, so manual Apple Development signing works without one (built and verified locally, RL-04). The release build also passes `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, so the shipped app has no `get-task-allow` (debugger) entitlement.

## Hardened Runtime

Release builds are signed with the **Hardened Runtime** (`flags=0x10000(runtime)` in `codesign -dv`). Without it any program running as the same user could start `Gio.app` with an injected library (`DYLD_INSERT_LIBRARIES`) and act with Gio's Accessibility and Screen Recording grants.

| Where | What |
| --- | --- |
| `Gio.xcodeproj` (target `Gio`, **Release** only) | `ENABLE_HARDENED_RUNTIME = YES`. Debug keeps it off: Xcode's debug builds (ad-hoc or personal-team signing, the debug dylib, attaching the debugger) are left exactly as before, and their Accessibility grant does not depend on it. |
| `release.yml` | Passes `ENABLE_HARDENED_RUNTIME=YES` explicitly as well. |
| `scripts/make-dmg.sh` | Fails unless `codesign -dv` reports the `runtime` flag. |
| In-app updater | Refuses a downloaded app without the flag (`codeSignatureHasHardenedRuntime`, checked next to the code requirement, because the requirement language cannot test signature flags). Every release is built this way from the first one on, so no published version lacks it. |

Gio needs **no** Hardened Runtime exception entitlements:

| Statement | Status |
| --- | --- |
| No JIT, no unsigned executable memory, no `DYLD_*` variables, no plug-ins: Gio loads its own signed code and system frameworks. The one `dlopen`/`dlsym` is Apple's private `MultitouchSupport` framework from `/System/Library/PrivateFrameworks` (trackpad gestures, `Multitouch.swift`), which library validation accepts because Apple signs it; SwiftPM products are linked into the signed bundle. | **Checked in the source** (search for `dlopen`, `dlsym`, `MAP_JIT`, `DYLD_`); that gestures load in a hardened build is [INFERENCE] until observed live. |
| No Apple Events are *sent* (`com.apple.security.automation.apple-events` is only for sending); `launchedAsLoginItem` reads the launch event Gio *receives*. | **Checked in the source.** |
| Accessibility (AX API, event taps) and Screen Recording (ScreenCaptureKit, window images) are TCC permissions, not Hardened Runtime resources: Apple's Hardened Runtime entitlement list covers camera, microphone, location, contacts, calendars, photos and Apple Events only. | **Documented** by Apple's Hardened Runtime entitlement list; that both keep working in a hardened Gio is [INFERENCE] until observed live. |
| A hardened Release build passes `codesign --verify --deep --strict` and its DR is unchanged. | **Verified locally** (see `odd/tasks/release.md`, RL-05). |

LIVE PENDING until the first hardened release: launch, Accessibility, Screen Recording, hotkeys, guardian restart and the updater on a hardened build.

## Workflow security

- Every action is pinned to a full commit SHA, with its version in a comment. To update one, look up the tag's commit (`git ls-remote --tags https://github.com/actions/checkout`) and replace the SHA and the comment together. Xcode is selected with `sudo xcode-select -s` (the newest stable `/Applications/Xcode_<version>.app` on the runner), no third-party action.
- The workflow token is read-only (`permissions: contents: read`); the **version** job reads pull requests, and only the **publish** job gets `contents: write`, and it runs no repository code: it downloads the built DMG, checks the SHA-256 and calls `gh release create`. **Prepare Release** gets `pull-requests: write` and `issues: write` (labels) and writes nothing else; GitHub's setting *Allow GitHub Actions to create and approve pull requests* is on for it.
- The signing secrets live in the `release` environment, reachable only from the **build** job of a run on `main` (a merged release pull request, or a dry run started on `main`). The **test** job runs `swift test` without them. A manual run from another branch skips the build job.
- The bump (a `release:*` label, matched as a whole string) and the version (computed, or a dispatch input) are checked by `scripts/release-version.sh` (bash `[[ =~ ]]`), so a newline cannot add lines to `$GITHUB_OUTPUT`, and a refused value is never echoed into a workflow command. Two `release:*` labels on one pull request are refused.
- Certificate revocation: the updater does **not** pass `kSecCSEnforceRevocationChecks`. With the network up it accepts a valid build and DMG (checked locally, UP-13), but it forces revocation checks regardless of the system preference, and whether a valid update is refused when `ocsp.apple.com` is unreachable while GitHub is reachable (a firewall, a filtering proxy) could not be tested; [INFERENCE] it would be, since the flag asks for a definite answer. A valid update must not fail that way. If the signing key ever leaks: revoke the certificate in the Apple Developer portal, rotate the environment secrets, and publish a release from a new certificate with the same CN; the environment (only `main`) and the `main` ruleset (only merged pull requests) are what keep the key from being used in the first place.

## Cut a release

1. Work lands on `dev` (the default branch); its CI must be green.
2. **Actions > Prepare Release > Run workflow**, branch `dev`, pick the bump (**patch**, **minor** or **major**). Or from a terminal: `gh workflow run prepare-release.yml --repo ismaelosuna7824/gio --ref dev -f bump=minor`. It opens the pull request `Release v0.2.0` (`dev` → `main`); running it again with another bump relabels and retitles the same pull request.
3. Edit the pull request's body if you want different release notes, then merge it with **Create a merge commit**.
4. The merge starts **Release**: `gh run watch --repo ismaelosuna7824/gio` (or the **Actions** tab). The version is computed again at the merge from the latest tag and the label, so the title never decides it. The release appears under **Releases** with `Gio-0.2.0.dmg`, `Gio-0.2.0.dmg.sha256` and `Gio.dmg`, and the apps out there offer it within a day.
5. If the run fails, nothing is published and no tag exists: fix on `dev` and prepare a new release pull request (or re-run the failed jobs when the failure was the runner's).

## Dry run and local DMG

- **CI dry run** (builds, signs, makes the DMG, publishes nothing): `gh workflow run release.yml --repo ismaelosuna7824/gio --ref main -f version=0.2.0-rc.1`, then download the `Gio-0.2.0-rc.1` artifact from the run. It needs the same secrets. A dispatch from any other branch runs the tests only.
- **Local DMG** with your own signing identity:

  ```sh
  xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Release \
    -derivedDataPath /tmp/GioRelease -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=2CAK428VHF \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES \
    MARKETING_VERSION=0.2.0-rc.1 CURRENT_PROJECT_VERSION=1 build
  GIO_EXPECTED_TEAM=2CAK428VHF scripts/make-dmg.sh /tmp/GioRelease/Build/Products/Release/Gio.app 0.2.0-rc.1 /tmp/dist
  ```

  `make-dmg.sh` refuses a bundle whose version differs from the argument, an ad-hoc signed or non-hardened bundle, and with `GIO_EXPECTED_TEAM` set, one signed by another team. It signs the DMG with the app's identity from your keychains (`GIO_KEYCHAIN` selects one keychain, as in CI); macOS may ask once to allow `codesign` to use the key.
- **Version step tests**: `scripts/test-release-version.sh` (no network, no secrets).

## What users see the first time

Because the app is not notarized, the first install from a browser download goes through Gatekeeper once:

1. Download `Gio-<version>.dmg` from the release page (optionally check it: `shasum -a 256 -c Gio-<version>.dmg.sha256` in the download folder).
2. Open the DMG and drag **Gio** onto **Applications**.
3. Open Gio. macOS refuses with a dialog saying Apple could not verify Gio is free of malware. Click **Done** (not **Move to Trash**).
4. Open **System Settings > Privacy & Security**, scroll to the message about Gio being blocked and click **Open Anyway**, then confirm with your password. On macOS 15 and later this is the only way; the old right-click **Open** shortcut no longer bypasses the check.
5. Grant **Accessibility** (and **Screen Recording** if prompted) as described in the [user guide](USER_GUIDE.md).

Later versions are installed by the in-app updater, which replaces the app with one carrying the same signature, so the grants stay. [INFERENCE] A file downloaded by the app itself (not a browser) carries no quarantine attribute unless the app sets one, so updates should not show the Gatekeeper dialog again; see the in-app updater section of [`odd/tasks/release.md`](../odd/tasks/release.md) for what was verified live.

## Certificate renewal and the designated requirement

macOS ties privacy grants to the app's **designated requirement** (DR). The DR of a build signed by this pipeline (verified with `codesign -d -r- Gio.app` on a local build with the release settings, RL-04):

```text
identifier "dev.gio.windowmanager" and anchor apple generic
and certificate leaf[subject.CN] = "Apple Development: ismaelosuna.ca@gmail.com (DPYR37JY5V)"
and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

| Statement | Status |
| --- | --- |
| The DR pins the bundle id and the leaf certificate's common name, not the certificate itself or its serial. | **Verified** (DR above). |
| Any build signed by an Apple-issued development certificate with that exact CN and bundle id satisfies it, so grants survive updates. | **Verified for builds from the current certificate** (`codesign --verify --strict` reports "satisfies its Designated Requirement"); [INFERENCE] macOS keeps the grant for a new build that satisfies the stored DR. |
| A renewed certificate for the same Apple ID and team keeps the same CN (the `DPYR37JY5V` developer identifier belongs to the account, not to one certificate). | [INFERENCE], not verified: no renewal has happened yet. |
| The current certificate expires **2027-02-23**. | **Verified** (`openssl x509 -noout -dates`). |

Renewal steps (before the expiry date):

1. Create a new Apple Development certificate in Xcode (**Settings > Accounts > Manage Certificates > +**) for the same Apple ID.
2. Check its name: `security find-identity -v -p codesigning` must show `Apple Development: ismaelosuna.ca@gmail.com (DPYR37JY5V)`. Then build locally and check the new build against the old DR: `codesign --verify -R='identifier "dev.gio.windowmanager" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: ismaelosuna.ca@gmail.com (DPYR37JY5V)" and certificate 1[field.1.2.840.113635.100.6.2.1]' Gio.app` exits 0 (verified with the current certificate; a build signed with a different CN fails with exit 3).
3. Export the new identity and replace the two `APPLE_DEVELOPMENT_P12_*` secrets ([setup](#one-time-setup-signing-secrets)), then cut a release.
4. If the CN changed (new e-mail, other account), users must grant Accessibility and Screen Recording again once after that update; say so in the release notes.

[INFERENCE] Apple Development signatures carry no secure timestamp, so after the certificate expires a newly downloaded copy of an old release may fail Gatekeeper; keep publishing from a valid certificate.

## Public repository

The repository is public (since RL-10): the app finds releases through `GioUpdateRepository` and the public GitHub API without a token, the workflow publishes with the job's own `GITHUB_TOKEN`, and anyone can download the DMG without signing in. The updater's token field only matters for a private fork.

## Troubleshooting

| Symptom in the run | Cause and fix |
| --- | --- |
| `Missing signing secrets in the release environment` | One of the three secrets is not set in the `release` environment (repository secrets are not used; secrets are not available to workflows from forks). |
| The build job fails with "branch/tag is not allowed to deploy" | The run is not on `main`: the `release` environment only deploys `main`. Dry runs must be dispatched with `--ref main`. |
| `is not signed with the Hardened Runtime` from `make-dmg.sh` | The build did not get `ENABLE_HARDENED_RUNTIME=YES` (Release configuration or the command-line setting). |
| `codesign` asks for the keychain password while signing the DMG locally | Allow it (**Always Allow** for `codesign`); in CI the partition list step does this. |
| `0 valid identities found` after the import | The `.p12` has no private key (exported the certificate, not the identity) or the password is wrong. Export again from **My Certificates**. |
| `errSecInternalComponent` or a hanging `CodeSign` | The key partition list was not set; the workflow runs `security set-key-partition-list`. Check `KEYCHAIN_PASSWORD` matches what created the keychain (it is the same secret in one run). |
| `make-dmg.sh: ... reports version X, expected Y` | `MARKETING_VERSION` did not reach the build; check the **version** job's output. |
| `signed by team '...', expected '2CAK428VHF'` | The wrong identity signed the app; check the secret holds the Apple Development identity of team `2CAK428VHF`. |
| Test step fails | Nothing is built or published. Fix on `dev` and prepare the release again. |
| `The version bump must be patch, minor or major` | The merged pull request has a `release:*` label other than those three, or two of them. Fix the labels and re-run the workflow. |
| `This commit is already released` | A re-run of a release that already published: nothing to do. |
