#!/bin/bash
# Xcode "Stamp dev version" build phase of the Gio target.
#
# A dev build (MARKETING_VERSION left at the 0.0.0-dev default of Config/Version.xcconfig)
# reports the last v* tag with "+dev" build metadata, for example 0.2.0+dev, so it is never
# mistaken for the release it was built after. Without a tag it keeps 0.0.0-dev.
# Release builds pass MARKETING_VERSION on the command line, so this does nothing for them.
set -euo pipefail

if [[ "${MARKETING_VERSION:-}" != "0.0.0-dev" ]]; then
    exit 0
fi

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
tag="$(git -C "${SRCROOT}" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [[ -z "${tag}" ]]; then
    exit 0
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${tag#v}+dev" "${plist}"
echo "Stamped dev version ${tag#v}+dev"
