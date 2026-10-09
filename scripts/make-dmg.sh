#!/bin/bash
# Package a built, signed Gio.app into the release DMG and its checksum.
#
#   scripts/make-dmg.sh <path/to/Gio.app> <version> [output-dir]
#
# Writes <output-dir>/Gio-<version>.dmg (Gio.app plus an Applications symlink, volume
# "Gio <version>") and Gio-<version>.dmg.sha256 ("<hex>  Gio-<version>.dmg").
# output-dir defaults to the current directory. Before packaging it verifies the app's
# signature (codesign --verify --deep --strict), requires an Apple-issued signing identity (not
# ad hoc) and the Hardened Runtime flag (flags=0x10000(runtime)), prints the signing team, and
# checks that the bundle's CFBundleShortVersionString equals <version>. Set GIO_EXPECTED_TEAM (CI
# does) to fail unless the app is signed by that team. The DMG itself is then signed with the
# app's identity (from GIO_KEYCHAIN when set, else the default keychains) and verified against
# `anchor apple generic` plus the app's team and certificate common name, the requirement the
# in-app updater checks before it mounts a downloaded image. Used by
# .github/workflows/release.yml and locally.
set -euo pipefail

usage() {
    echo "usage: $0 <path/to/Gio.app> <version> [output-dir]" >&2
    exit 64
}

[[ $# -ge 2 && $# -le 3 ]] || usage
app="${1%/}"
version="$2"
out_dir="${3:-.}"

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "error: version '${version}' is not MAJOR.MINOR.PATCH[-prerelease]" >&2
    exit 64
fi
if [[ ! -d "${app}" || "$(basename "${app}")" != "Gio.app" ]]; then
    echo "error: '${app}' is not a Gio.app bundle" >&2
    exit 66
fi

bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist")"
if [[ "${bundle_version}" != "${version}" ]]; then
    echo "error: ${app} reports version ${bundle_version}, expected ${version}" >&2
    exit 65
fi

echo "==> Verifying the signature of ${app}"
codesign --verify --deep --strict --verbose=2 "${app}"
signing_info="$(codesign -dvv "${app}" 2>&1)"
team="$(printf '%s\n' "${signing_info}" | awk -F= '/^TeamIdentifier=/ { print $2 }')"
authority="$(printf '%s\n' "${signing_info}" | awk -F= '/^Authority=/ { print $2; exit }')"
echo "    team: ${team:-unknown}"
echo "    authority: ${authority:-none (ad-hoc)}"
if [[ -n "${GIO_EXPECTED_TEAM:-}" && "${team}" != "${GIO_EXPECTED_TEAM}" ]]; then
    echo "error: signed by team '${team}', expected '${GIO_EXPECTED_TEAM}'" >&2
    exit 65
fi
if [[ -z "${team}" || "${team}" == "not set" || -z "${authority}" || "${team}${authority}" == *'"'* ]]; then
    echo "error: ${app} is not signed with an Apple-issued identity (ad hoc or unreadable team)" >&2
    exit 65
fi
if ! printf '%s\n' "${signing_info}" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime'; then
    echo "error: ${app} is not signed with the Hardened Runtime (build with ENABLE_HARDENED_RUNTIME=YES)" >&2
    exit 65
fi
echo "    hardened runtime: yes"
image_requirement="anchor apple generic and certificate leaf[subject.OU] = \"${team}\" and certificate leaf[subject.CN] = \"${authority}\""
keychain_args=()
if [[ -n "${GIO_KEYCHAIN:-}" ]]; then
    keychain_args=(--keychain "${GIO_KEYCHAIN}")
fi

mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"
dmg_name="Gio-${version}.dmg"
dmg="${out_dir}/${dmg_name}"

staging="$(mktemp -d "${TMPDIR:-/tmp}/gio-dmg.XXXXXX")"
trap 'rm -rf "${staging}"' EXIT

echo "==> Staging Gio.app and the Applications link"
ditto "${app}" "${staging}/Gio.app"
ln -s /Applications "${staging}/Applications"

echo "==> Creating ${dmg}"
rm -f "${dmg}" "${dmg}.sha256"
hdiutil create -volname "Gio ${version}" -srcfolder "${staging}" -fs HFS+ -format UDZO -ov "${dmg}"

echo "==> Signing ${dmg_name} as ${authority}"
codesign --sign "${authority}" "${keychain_args[@]+"${keychain_args[@]}"}" "${dmg}"
codesign --verify --strict --verbose=2 "-R=${image_requirement}" "${dmg}"
hdiutil verify "${dmg}"

(cd "${out_dir}" && shasum -a 256 "${dmg_name}" > "${dmg_name}.sha256")
echo "==> Wrote ${dmg}"
echo "    sha256: $(cat "${dmg}.sha256")"
