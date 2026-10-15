# Releasing Gio

How a Gio release is versioned, signed, built and published, and what users see when they install it. Decisions and evidence: [`odd/tasks/release.md`](../odd/tasks/release.md) (RL-01..).

Contents: [Overview](#overview) · [Versioning](#versioning) · [One-time setup: signing secrets](#one-time-setup-signing-secrets) · [Hardened Runtime](#hardened-runtime) · [Workflow security](#workflow-security) · [Cut a release](#cut-a-release) · [Dry run and local DMG](#dry-run-and-local-dmg) · [What users see](#what-users-see-the-first-time) · [Certificate renewal](#certificate-renewal-and-the-designated-requirement) · [When the repo becomes public](#when-the-repository-becomes-public) · [Troubleshooting](#troubleshooting)

## Overview

| Piece | What it does |
| --- | --- |
| Tag `vMAJOR.MINOR.PATCH[-prerelease]` | The only thing a maintainer does by hand. `v0.2.0`, `v0.2.0-beta.1`. |
| `.github/workflows/release.yml` | On a pushed `v*` tag, three jobs: **test** (`swift test`, no secrets; a failure stops the release), **build** (in the protected `release` environment: a Release build with the Hardened Runtime signed with the **Apple Development** identity from the environment secrets, then the signed DMG, uploaded as an artifact) and **publish** (the only job with `contents: write`; downloads the artifact, checks its SHA-256 and runs `gh release create` with the assets). A version with a `-` becomes a GitHub **prerelease**. The macOS jobs run on the `xcode-27` runner image (arm64, macOS 27) with its newest stable Xcode: older toolchains (`macos-15`'s Xcode 16.4) do not compile the sources and cannot build the Icon Composer app icon. |
| `scripts/release-version.sh` | The workflow's version step: tag or dispatch input to `tag`/`version`/`publish`/`prerelease`; refuses anything but `MAJOR.MINOR.PATCH[-prerelease]` without echoing it. Tests: `scripts/test-release-version.sh`. |
| `scripts/make-dmg.sh` | Verifies the app signature (`codesign --verify --deep --strict`, prints the team), requires an Apple-issued identity and the Hardened Runtime flag, checks the bundle version, writes `Gio-<version>.dmg` (volume `Gio <version>`: `Gio.app` plus an `Applications` link), signs the DMG with the app's identity and verifies that signature, then writes `Gio-<version>.dmg.sha256` (`<hex>  Gio-<version>.dmg`). |
| Release assets | `Gio-<version>.dmg`, `Gio-<version>.dmg.sha256` (what the in-app updater reads), and `Gio.dmg`, the same DMG under a fixed name so `https://github.com/ismaelosuna7824/gio/releases/latest/download/Gio.dmg` always serves the newest stable release (the landing page's Download buttons; prereleases are never "latest"). The release body is the tag annotation, or GitHub's generated notes when the tag has none. |

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

The workflow needs three secrets, stored in the GitHub **environment** `release` (not as repository secrets), so only the build job of an approved run can read them. Never commit a certificate, a `.p12`, a password or a token.

0. **Create the `release` environment** (done once by the maintainer on GitHub; an agent cannot do it). **Settings > Environments > New environment**, name `release`:
   - **Required reviewers**: add yourself (and anyone else allowed to ship). Every signing run then waits for an approval in the run page.
   - **Deployment branches and tags**: **Selected branches and tags**, add the tag rule `v*`. Add the branch `main` too if you want CI dry runs (`workflow_dispatch`); the workflow refuses to sign a dispatch from any other branch anyway.
   - Optional but recommended: **Settings > Rules > Rulesets > New tag ruleset** targeting `v*`, restricting creation, update and deletion to the maintainers (bypass list), so nobody else can start a release by pushing a tag.

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
- The workflow token is read-only (`permissions: contents: read`); only the **publish** job gets `contents: write`, and it runs no repository code: it downloads the built DMG, checks the SHA-256 and calls `gh release create`.
- The signing secrets live in the `release` environment, reachable only from the **build** job after a reviewer approved it, for a `v*` tag (or `main`, if you allowed dry runs). The **test** job runs `swift test` without them. A manual run from another branch skips the build job.
- The version (tag or dispatch input) is checked as a whole string (`scripts/release-version.sh`, bash `[[ =~ ]]`), so a newline cannot add lines to `$GITHUB_OUTPUT`, and a refused value is never echoed into a workflow command.
- Certificate revocation: the updater does **not** pass `kSecCSEnforceRevocationChecks`. With the network up it accepts a valid build and DMG (checked locally, UP-13), but it forces revocation checks regardless of the system preference, and whether a valid update is refused when `ocsp.apple.com` is unreachable while GitHub is reachable (a firewall, a filtering proxy) could not be tested; [INFERENCE] it would be, since the flag asks for a definite answer. A valid update must not fail that way. If the signing key ever leaks: revoke the certificate in the Apple Developer portal, rotate the environment secrets, and publish a release from a new certificate with the same CN; the protected environment and the reviewer are what keep the key from being used in the first place.

## Cut a release

1. Make sure the branch you release from is green in CI and contains everything you want shipped.
2. Create an **annotated** tag; its message becomes the release notes (first line as a heading line, the rest as the body):

   ```sh
   git tag -a v0.2.0 -m "Gio 0.2.0" -m "- Self-updating app
   - Signed DMG releases"
   git push origin v0.2.0
   ```

   A prerelease: `git tag -a v0.3.0-beta.1 -m "..." && git push origin v0.3.0-beta.1`. A lightweight tag (or an empty annotation) gets GitHub's generated notes instead.
3. Watch the run: `gh run watch --repo ismaelosuna7824/gio` (or the **Actions** tab). After **test** passes, the **build** job waits for your approval (**Review deployments > release > Approve and deploy**). The release appears under **Releases** with `Gio-0.2.0.dmg` and `Gio-0.2.0.dmg.sha256`.
4. If the run fails, nothing is published. Fix the problem, delete the tag (`git push origin :refs/tags/v0.2.0 && git tag -d v0.2.0`) and tag again, or tag the next patch version.

## Dry run and local DMG

- **CI dry run** (builds, signs, makes the DMG, publishes nothing): `gh workflow run release.yml --repo ismaelosuna7824/gio --ref main -f version=0.2.0-rc.1`, approve the `release` deployment, then download the `Gio-0.2.0-rc.1` artifact from the run. It needs the same secrets, and `main` allowed in the environment's deployment rule. A dispatch from any other branch runs the tests only.
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

## When the repository becomes public

Nothing changes in the app or the workflow: the app finds releases through `GioUpdateRepository` and the public GitHub API, and the workflow publishes with the job's own `GITHUB_TOKEN`. While the repository is private the in-app updater needs a personal access token with read access; once it is public that token field becomes unnecessary and can be cleared. Users can also download the DMG from the release page without signing in.

## Troubleshooting

| Symptom in the run | Cause and fix |
| --- | --- |
| `Missing signing secrets in the release environment` | One of the three secrets is not set in the `release` environment (repository secrets are not used; secrets are not available to workflows from forks). |
| The build job waits forever, or fails with "branch/tag is not allowed to deploy" | Approve the `release` deployment in the run page; for a dry run, allow `main` in the environment's deployment branches and tags and dispatch with `--ref main`. |
| `is not signed with the Hardened Runtime` from `make-dmg.sh` | The build did not get `ENABLE_HARDENED_RUNTIME=YES` (Release configuration or the command-line setting). |
| `codesign` asks for the keychain password while signing the DMG locally | Allow it (**Always Allow** for `codesign`); in CI the partition list step does this. |
| `0 valid identities found` after the import | The `.p12` has no private key (exported the certificate, not the identity) or the password is wrong. Export again from **My Certificates**. |
| `errSecInternalComponent` or a hanging `CodeSign` | The key partition list was not set; the workflow runs `security set-key-partition-list`. Check `KEYCHAIN_PASSWORD` matches what created the keychain (it is the same secret in one run). |
| `make-dmg.sh: ... reports version X, expected Y` | `MARKETING_VERSION` did not reach the build; check the tag format (`v` plus semver). |
| `signed by team '...', expected '2CAK428VHF'` | The wrong identity signed the app; check the secret holds the Apple Development identity of team `2CAK428VHF`. |
| Test step fails | Nothing is built or published. Fix on the branch, retag. |
