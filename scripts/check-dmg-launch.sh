#!/bin/bash
set -euo pipefail

launch=true
if [[ "${1:-}" == "--no-launch" ]]; then
    launch=false
    shift
fi
if [[ $# -ne 1 ]]; then
    printf 'Usage: %s [--no-launch] disk-image.dmg\n' "$0" >&2
    exit 2
fi

script_directory="$(cd "$(dirname "$0")" && pwd)"
staging="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/muk-install.XXXXXX")"
mountpoint="$staging/DMG"
attached=false
cleanup() {
    if [[ "$attached" == true ]]; then
        hdiutil detach "$mountpoint" -quiet || return 1
    fi
    rm -r "$staging"
}
trap cleanup EXIT
mkdir "$mountpoint" "$staging/Applications"
hdiutil attach "$1" -quiet -readonly -nobrowse -noautoopen -mountpoint "$mountpoint"
attached=true

test "$(readlink "$mountpoint/Applications")" = /Applications
mounted="$mountpoint/Mac Utility Kit.app"
installed="$staging/Applications/Mac Utility Kit.app"
ditto "$mounted" "$installed"
minimum="$(plutil -extract LSMinimumSystemVersion raw -o - "$installed/Contents/Info.plist")"
if [[ ! "$minimum" =~ ^15(\.0){0,2}$ ]]; then
    printf 'Expected the app bundle to declare macOS 15.0, found %s.\n' "$minimum" >&2
    exit 1
fi
architecture="$(uname -m)"
for executable in MacUtilityKit muk; do
    binary="$installed/Contents/MacOS/$executable"
    if ! xcrun vtool -arch "$architecture" -show-build "$binary" | awk '
        $1 == "platform" { macos = ($2 == "MACOS") }
        $1 == "minos" && macos && $2 ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/ {
            split($2, version, ".")
            if ((version[1] < 15) || (version[1] == 15 && version[2] == 0 && version[3] == 0)) supported = 1
        }
        END { exit !supported }
    '; then
        printf '%s must contain a %s executable loadable on macOS 15.0.\n' "$executable" "$architecture" >&2
        exit 1
    fi
done
if [[ "$launch" == true ]]; then
    swift "$script_directory/check-app-launch.swift" "$mounted"
fi
hdiutil detach "$mountpoint" -quiet
attached=false
codesign --verify --deep --strict "$installed"
if [[ "$launch" == true ]]; then
    swift "$script_directory/check-app-launch.swift" "$installed"
fi
