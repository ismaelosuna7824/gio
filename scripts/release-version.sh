#!/bin/bash
# The release workflow's "Resolve the version" step (.github/workflows/release.yml).
#
#   EVENT_NAME=push REF_NAME=v0.2.0 GITHUB_OUTPUT=<file> scripts/release-version.sh
#   EVENT_NAME=workflow_dispatch INPUT_VERSION=0.2.0-rc.1 GITHUB_OUTPUT=<file> scripts/release-version.sh
#
# A pushed tag vMAJOR.MINOR.PATCH[-prerelease] publishes; a manual run is a dry run of that
# version. Appends tag=, version=, publish= and prerelease= to $GITHUB_OUTPUT, or fails without
# writing anything. The whole string is matched with bash [[ =~ ]] (a newline cannot sneak in
# extra output lines), and the refusal never echoes the input into a workflow command.
# Tested by scripts/test-release-version.sh.
set -euo pipefail

semver='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

case "${EVENT_NAME:-}" in
    push)
        tag="${REF_NAME:-}"
        version="${tag#v}"
        publish=true
        ;;
    workflow_dispatch)
        version="${INPUT_VERSION:-}"
        tag="v${version}"
        publish=false
        ;;
    *)
        echo "::error::Releases start from a pushed v* tag or a manual dry run"
        exit 1
        ;;
esac

if [[ ! "${version}" =~ ${semver} || "${tag}" != "v${version}" ]]; then
    echo "::error::The version must be MAJOR.MINOR.PATCH[-prerelease] (tags: vMAJOR.MINOR.PATCH[-prerelease])"
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
