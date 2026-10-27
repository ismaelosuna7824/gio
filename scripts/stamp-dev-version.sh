#!/bin/bash
# Xcode "Stamp dev version" build phase of the Gio target.
#
#   scripts/stamp-dev-version.sh <source Info.plist> <output Info.plist>
#
# Writes the Info.plist the target processes (INFOPLIST_FILE, in DERIVED_FILE_DIR) from the
# tracked source plist. A dev build (MARKETING_VERSION left at the 0.0.0-dev default of
# Config/Version.xcconfig) reports the last v* tag with "+dev" build metadata, for example
# 0.2.0+dev, so it is never mistaken for the release it was built after. Without a tag, and for
# release builds (MARKETING_VERSION passed on the command line), the output is the source plist
# unchanged and Xcode substitutes $(MARKETING_VERSION) as usual.
#
# The output is only rewritten when its content changes: an unchanged file keeps its timestamp,
# so Xcode neither re-processes the Info.plist nor re-signs the app on an incremental build.
# The phase declares the git files that move the result (HEAD, its reflog, packed-refs,
# refs/tags) as inputs, so it runs again after a checkout, commit, merge, fetch or new tag.
# Tested by scripts/test-stamp-dev-version.sh.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <source Info.plist> <output Info.plist>" >&2
    exit 64
fi
source_plist="$1"
output_plist="$2"

mkdir -p "$(dirname "${output_plist}")"
staged="$(mktemp "${output_plist}.XXXXXX")"
trap 'rm -f "${staged}"' EXIT
cp "${source_plist}" "${staged}"

if [[ "${MARKETING_VERSION:-}" == "0.0.0-dev" ]]; then
    tag="$(git -C "${SRCROOT}" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
    if [[ -n "${tag}" ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${tag#v}+dev" "${staged}"
    fi
fi

if cmp -s "${staged}" "${output_plist}"; then
    exit 0
fi
mv -f "${staged}" "${output_plist}"
echo "Wrote ${output_plist} ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${output_plist}"))"
