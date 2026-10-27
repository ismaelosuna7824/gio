#!/bin/bash
# Tests for scripts/stamp-dev-version.sh (the Xcode "Stamp dev version" build phase). Run locally:
#   scripts/test-stamp-dev-version.sh
# Each case uses a throwaway git repository under TMPDIR. Prints one line per case and exits
# non-zero when any case fails.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
subject="${here}/stamp-dev-version.sh"
source_plist="${here}/../Gio.xcodeproj/Gio-Info.plist"
work="$(mktemp -d "${TMPDIR:-/tmp}/gio-stamp-dev-version.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

g() { # git in the throwaway repository, never signing, never reading the user's identity
    git -C "${work}/repo" -c user.name=gio-test -c user.email=gio-test@example.invalid \
        -c commit.gpgsign=false -c tag.gpgsign=false "$@" > /dev/null 2>&1
}

# stamp <marketing version> [srcroot]: runs the phase like Xcode does; sets status, log.
out="${work}/derived/Gio-Info.plist"
stamp() {
    log="$(SRCROOT="${2:-${work}/repo}" MARKETING_VERSION="$1" GIT_CEILING_DIRECTORIES="${work}" \
        bash "${subject}" "${source_plist}" "${out}" 2>&1)"
    status=$?
}

short_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${out}" 2>/dev/null; }
inode() { stat -f '%i' "${out}"; }

expect_version() { # <name> <expected CFBundleShortVersionString>
    local actual
    actual="$(short_version)"
    if [[ ${status} -eq 0 && "${actual}" == "$2" ]]; then pass "$1"; else fail "$1 (status ${status}, version: ${actual}, log: ${log})"; fi
}

expect_verbatim() { # <name>
    if [[ ${status} -eq 0 ]] && cmp -s "${source_plist}" "${out}"; then pass "$1"; else fail "$1 (status ${status}, log: ${log})"; fi
}

mkdir -p "${work}/repo" "${work}/not-a-repo"
g init -q
g commit -q --allow-empty -m first

stamp 0.0.0-dev
expect_verbatim "a dev build without a tag keeps the source plist (0.0.0-dev)"

g tag v0.3.0
stamp 0.0.0-dev
expect_version "a dev build reports the last tag plus +dev" '0.3.0+dev'
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${out}" 2>/dev/null)"
# shellcheck disable=SC2016 # the literal, unexpanded build setting reference
if [[ "${executable}" == '$(EXECUTABLE_NAME)' ]]; then
    pass "other keys keep their build setting references"
else
    fail "other keys keep their build setting references (CFBundleExecutable: ${executable})"
fi

before="$(inode)"
g commit -q --allow-empty -m second
stamp 0.0.0-dev
if [[ ${status} -eq 0 && "$(inode)" == "${before}" && "$(short_version)" == '0.3.0+dev' ]]; then
    pass "an unchanged version leaves the output untouched (no re-process, no re-sign)"
else
    fail "an unchanged version leaves the output untouched (status ${status}, log: ${log})"
fi

g tag v0.4.0
stamp 0.0.0-dev
expect_version "a new tag is picked up on the next build" '0.4.0+dev'

g tag build-7
stamp 0.0.0-dev
expect_version "only v* tags count" '0.4.0+dev'

stamp 1.2.3
expect_verbatim "a release build (MARKETING_VERSION set) keeps the source plist"

stamp 0.0.0-dev "${work}/not-a-repo"
expect_verbatim "a source tree without git keeps the source plist"

if [[ ${failures} -ne 0 ]]; then
    echo "${failures} case(s) failed" >&2
    exit 1
fi
echo "all cases passed"
