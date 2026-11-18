#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
binary_directory="$(swift build -c release --show-bin-path)"
app="build/Mac Utility Kit.app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_directory/MacUtilityKit" "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacUtilityKit</string>
    <key>CFBundleIdentifier</key><string>app.macutilitykit.preview</string>
    <key>CFBundleName</key><string>Mac Utility Kit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
