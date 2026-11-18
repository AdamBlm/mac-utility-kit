#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-build/Mac Utility Kit.app}"
destination="${2:-build/Mac Utility Kit Preview.dmg}"
if [[ -e "$destination" || -L "$destination" ]]; then
    printf 'Choose a new disk image path: %s\n' "$destination" >&2
    exit 1
fi
codesign --verify --deep --strict "$app"

destination_parent="$(cd "$(dirname "$destination")" && pwd -P)"
stage="$(mktemp -d "$destination_parent/.muk-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
payload="$stage/Installer"
mkdir "$payload"
ditto "$app" "$payload/Mac Utility Kit.app"
ln -s /Applications "$payload/Applications"

image="$stage/Mac Utility Kit.dmg"
hdiutil create -quiet -srcfolder "$payload" -volname "Mac Utility Kit" -format UDZO "$image"
hdiutil verify "$image"
ln "$image" "$destination"
printf '%s\n' "$destination"
