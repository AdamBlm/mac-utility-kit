#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Pass the path to a Mac Utility Kit disk image.\n' >&2
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
hdiutil attach "$1" -quiet -readonly -nobrowse -mountpoint "$mountpoint"
attached=true

test "$(readlink "$mountpoint/Applications")" = /Applications
mounted="$mountpoint/Mac Utility Kit.app"
installed="$staging/Applications/Mac Utility Kit.app"
ditto "$mounted" "$installed"
swift "$script_directory/check-app-launch.swift" "$mounted"
hdiutil detach "$mountpoint" -quiet
attached=false
codesign --verify --deep --strict "$installed"
swift "$script_directory/check-app-launch.swift" "$installed"
