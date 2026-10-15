#!/bin/bash
# The release workflow's "Resolve the version" step (.github/workflows/release.yml), also used by
# the Prepare Release workflow to preview the version a release PR will publish.
#
#   EVENT_NAME=push REF_NAME=main LATEST_TAG=v0.1.0 BUMP=minor HEAD_TAGS= GITHUB_OUTPUT=<file> \
#       scripts/release-version.sh                                  # -> v0.2.0, published
#   EVENT_NAME=workflow_dispatch INPUT_VERSION=0.2.0-rc.1 GITHUB_OUTPUT=<file> scripts/release-version.sh
#
# A merge to main publishes the next version: the latest stable tag (LATEST_TAG, empty before the
# first release) bumped by BUMP (patch, the default when empty; minor; major). HEAD_TAGS lists the
# v* tags already on the merged commit: a commit that is already released is refused, so a re-run
# never publishes it twice. A manual run is a dry run of INPUT_VERSION. Appends tag=, version=,
# publish= and prerelease= to $GITHUB_OUTPUT, or fails without writing anything. Every input is
# matched as a whole string with bash [[ =~ ]] (a newline cannot sneak in extra output lines), and
# a refusal never echoes the input into a workflow command.
# Tested by scripts/test-release-version.sh.
set -euo pipefail

semver='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
stable_tag='^v([0-9]+)\.([0-9]+)\.([0-9]+)$'

case "${EVENT_NAME:-}" in
    push)
        if [[ "${REF_NAME:-}" != "main" ]]; then
            echo "::error::Releases publish only from a merge to main"
            exit 1
        fi
        if [[ -n "${HEAD_TAGS:-}" ]]; then
            echo "::error::This commit is already released; nothing to publish"
            exit 1
        fi
        latest="${LATEST_TAG:-v0.0.0}"
        if [[ ! "${latest}" =~ ${stable_tag} ]]; then
            echo "::error::The latest release tag must be vMAJOR.MINOR.PATCH"
            exit 1
        fi
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        patch="${BASH_REMATCH[3]}"
        case "${BUMP:-patch}" in
            patch) patch=$((10#${patch} + 1)) ;;
            minor) minor=$((10#${minor} + 1)); patch=0 ;;
            major) major=$((10#${major} + 1)); minor=0; patch=0 ;;
            *)
                echo "::error::The version bump must be patch, minor or major"
                exit 1
                ;;
        esac
        version="$((10#${major})).$((10#${minor})).$((10#${patch}))"
        tag="v${version}"
        publish=true
        ;;
    workflow_dispatch)
        version="${INPUT_VERSION:-}"
        tag="v${version}"
        publish=false
        ;;
    *)
        echo "::error::Releases start from a merge to main or a manual dry run"
        exit 1
        ;;
esac

if [[ ! "${version}" =~ ${semver} || "${tag}" != "v${version}" ]]; then
    echo "::error::The version must be MAJOR.MINOR.PATCH[-prerelease]"
    exit 1
fi

if [[ "${version}" == *-* ]]; then
    prerelease=true
else
    prerelease=false
fi

{
    echo "tag=${tag}"
    echo "version=${version}"
    echo "publish=${publish}"
    echo "prerelease=${prerelease}"
} >> "${GITHUB_OUTPUT}"
echo "Version ${version} (tag ${tag}, publish ${publish}, prerelease ${prerelease})"
