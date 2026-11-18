#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-build/Mac Utility Kit.app}"
destination="${2:-build/Mac Utility Kit Preview.dmg}"
identity="${MUK_CODESIGN_IDENTITY:--}"
notary_profile="${MUK_NOTARY_PROFILE:-}"
if [[ -e "$destination" || -L "$destination" ]]; then
    printf 'Choose a new disk image path: %s\n' "$destination" >&2
    exit 1
fi
if [[ -n "$notary_profile" && "$identity" == "-" ]]; then
    printf 'Notarization requires MUK_CODESIGN_IDENTITY to name a Developer ID Application identity.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
if [[ -n "$notary_profile" ]]; then
    developer_id='=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    codesign --verify --strict --test-requirement="$developer_id" "$app"
    codesign --verify --strict --test-requirement="$developer_id" "$app/Contents/MacOS/muk"
fi

destination_parent="$(cd "$(dirname "$destination")" && pwd -P)"
stage="$(mktemp -d "$destination_parent/.muk-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
payload="$stage/Installer"
mkdir "$payload"
ditto "$app" "$payload/Mac Utility Kit.app"
ln -s /Applications "$payload/Applications"

image="$stage/Mac Utility Kit.dmg"
hdiutil create -quiet -srcfolder "$payload" -volname "Mac Utility Kit" -format UDZO "$image"
if [[ "$identity" != "-" ]]; then
    codesign --sign "$identity" --timestamp --identifier app.macutilitykit.disk-image "$image"
fi
if [[ -n "$notary_profile" ]]; then
    codesign --verify --deep --strict "$payload/Mac Utility Kit.app"
    codesign --verify --strict --test-requirement="$developer_id" "$image"
    hdiutil verify "$image"
    submission="$stage/notarization.json"
    if ! xcrun notarytool submit "$image" --keychain-profile "$notary_profile" --wait --output-format json > "$submission"; then
        cat "$submission" >&2
        exit 1
    fi
    status="$(plutil -extract status raw -o - "$submission")"
    if [[ "$status" != "Accepted" ]]; then
        cat "$submission" >&2
        exit 1
    fi
    cat "$submission" >&2
    submission_id="$(plutil -extract id raw -o - "$submission")"
    xcrun notarytool log "$submission_id" --keychain-profile "$notary_profile" "$stage/notary-log.json"
    cat "$stage/notary-log.json" >&2
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
fi
if [[ "$identity" != "-" ]]; then
    codesign --verify --strict "$image"
fi
hdiutil verify "$image"
/bin/link "$image" "$destination"
printf '%s\n' "$destination"
