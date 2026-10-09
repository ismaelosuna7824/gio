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

# run <event> <ref name> <input version>: sets status, out (GITHUB_OUTPUT content), log (stdout+stderr).
run() {
    : > "${work}/output"
    log="$(EVENT_NAME="$1" REF_NAME="$2" INPUT_VERSION="$3" GITHUB_OUTPUT="${work}/output" \
        bash "${subject}" 2>&1)"
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

run push v0.2.0 ""
expect_ok "tag push publishes a release" "tag=v0.2.0${nl}version=0.2.0${nl}publish=true${nl}prerelease=false"

run push v0.3.0-beta.1 ""
expect_ok "tag push with a prerelease" "tag=v0.3.0-beta.1${nl}version=0.3.0-beta.1${nl}publish=true${nl}prerelease=true"

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

run push v1.2 ""
expect_refused "tag without a patch number" "v1.2"

run push 1.2.3 ""
expect_refused "tag without the v prefix" "1.2.3"

run push "v1.2.3${nl}publish=false" ""
expect_refused "tag name with a newline" "publish=false"

run schedule main 0.2.0
expect_refused "unknown event" "0.2.0"

if [[ ${failures} -ne 0 ]]; then
    echo "${failures} case(s) failed" >&2
    exit 1
fi
echo "all cases passed"
