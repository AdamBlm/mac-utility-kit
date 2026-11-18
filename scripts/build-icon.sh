#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s source.svg output.icns\n' "$0" >&2
    exit 2
fi

source_svg="$1"
output_icon="$2"
icon_workdir="$(mktemp -d "${TMPDIR:-/tmp}/mac-utility-icon.XXXXXX")"
trap 'rm -rf "$icon_workdir"' EXIT
iconset="$icon_workdir/AppIcon.iconset"
mkdir -p "$iconset"

sips -s format png "$source_svg" --out "$icon_workdir/master.png" >/dev/null
for size in 16 32 64 128 256 512 1024; do
    sips -z "$size" "$size" "$icon_workdir/master.png" --out "$icon_workdir/$size.png" >/dev/null
done
for size in 16 32 128 256 512; do
    cp "$icon_workdir/$size.png" "$iconset/icon_${size}x${size}.png"
    cp "$icon_workdir/$((size * 2)).png" "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o "$output_icon"
