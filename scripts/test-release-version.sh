#!/bin/bash
# Tests for scripts/release-version.sh (the release workflow's version step). Run locally:
#   scripts/test-release-version.sh
# Prints one line per case and exits non-zero when any case fails.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
subject="${here}/release-version.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/gio-release-version.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
failures=0

# run <event> <ref name> <input version> [latest tag] [bump] [tags at HEAD]: sets status, out
# (GITHUB_OUTPUT content), log (stdout+stderr).
run() {
    : > "${work}/output"
    log="$(EVENT_NAME="$1" REF_NAME="$2" INPUT_VERSION="$3" LATEST_TAG="${4:-}" BUMP="${5:-}" \
        HEAD_TAGS="${6:-}" GITHUB_OUTPUT="${work}/output" bash "${subject}" 2>&1)"
    status=$?
    out="$(cat "${work}/output")"
}

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

expect_ok() { # <name> <expected GITHUB_OUTPUT>
    if [[ ${status} -eq 0 && "${out}" == "$2" ]]; then pass "$1"; else fail "$1 (status ${status}, output: ${out})"; fi
}

expect_refused() { # <name> <text that must not be echoed>
    if [[ ${status} -ne 0 && -z "${out}" && "${log}" == *"::error::"* && "${log}" != *"$2"* ]]; then
        pass "$1"
    else
        fail "$1 (status ${status}, output: ${out}, log: ${log})"
    fi
}

nl=$'\n'

release() { # <name> <latest tag> <bump> <expected version>
    run push main "" "$2" "$3"
    expect_ok "$1" "tag=v$4${nl}version=$4${nl}publish=true${nl}prerelease=false"
}

release "a merge to main publishes the next patch" v0.1.0 patch 0.1.1
release "minor resets the patch" v0.1.7 minor 0.2.0
release "major resets minor and patch" v0.9.3 major 1.0.0
release "no bump label means patch" v0.1.0 "" 0.1.1
release "numbers grow past 9" v0.9.9 minor 0.10.0
release "the first release without any tag" "" minor 0.1.0

run push main "" v0.1.0 huge
expect_refused "unknown bump" "huge"

run push main "" v0.1.0 "minor${nl}tag=v9.9.9"
expect_refused "bump with a newline" "v9.9.9"

run push main "" v1.2 patch
expect_refused "latest tag without a patch number" "v1.2"

run push main "" "v1.2.3${nl}publish=false" patch
expect_refused "latest tag with a newline" "publish=false"

run push dev "" v0.1.0 patch
expect_refused "a push to another branch never publishes" "dev"

run push main "" v0.1.0 patch v0.1.0
expect_refused "a commit that is already released" "v0.1.1"

run workflow_dispatch main 0.2.0-rc.1
expect_ok "dispatch is a dry run" "tag=v0.2.0-rc.1${nl}version=0.2.0-rc.1${nl}publish=false${nl}prerelease=true"

run workflow_dispatch main "0.2.0${nl}tag=v9.9.9"
expect_refused "newline injection after a valid line" "v9.9.9"

run workflow_dispatch main "evil=1${nl}0.2.0"
expect_refused "newline injection before a valid line" "evil=1"

run workflow_dispatch main "0.2.0 ::warning::x"
expect_refused "trailing text" "::warning::x"

run workflow_dispatch main ""
expect_refused "empty version" "tag="

run workflow_dispatch main "v0.2.0"
expect_refused "dispatch version with a v" "v0.2.0"

run schedule main 0.2.0
expect_refused "unknown event" "0.2.0"

if [[ ${failures} -ne 0 ]]; then
    echo "${failures} case(s) failed" >&2
    exit 1
fi
echo "all cases passed"
