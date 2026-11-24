#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bundle_id="${MUK_BUNDLE_ID-app.macutilitykit.preview}"
release_version="${MUK_RELEASE_VERSION-0.0.1}"
build_version="${MUK_BUILD_VERSION-3}"
if [[ ! "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    printf 'MUK_BUNDLE_ID must contain dot-separated letters, digits, or hyphens.\n' >&2
    exit 2
fi
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'MUK_RELEASE_VERSION must contain three dot-separated integers.\n' >&2
    exit 2
fi
if [[ ! "$build_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    printf 'MUK_BUILD_VERSION must contain one to three dot-separated integers.\n' >&2
    exit 2
fi
swift build -c release
binary_directory="$(swift build -c release --show-bin-path)"
app="build/Mac Utility Kit.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
./scripts/build-icon.sh assets/branding/mac-utility-kit.svg "$app/Contents/Resources/AppIcon.icns"
cp "$binary_directory/MacUtilityKit" "$binary_directory/muk" "$app/Contents/MacOS/"
ditto "$binary_directory/KeyboardShortcuts_KeyboardShortcuts.bundle" \
    "$app/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle"
/usr/bin/install -m 0644 .build/checkouts/KeyboardShortcuts/license "$app/Contents/Resources/KeyboardShortcuts-LICENSE.txt"
mkdir -p "$app/Contents/Resources/CLI-Licenses"
for dependency in eventsource swift-argument-parser swift-atomics swift-collections swift-log swift-nio swift-sdk swift-subprocess swift-system; do
    case "$dependency" in
        eventsource) license="LICENSE.md" ;;
        swift-sdk|swift-subprocess) license="LICENSE" ;;
        *) license="LICENSE.txt" ;;
    esac
    checkout=".build/checkouts/$dependency"
    /usr/bin/install -m 0644 "$checkout/$license" "$app/Contents/Resources/CLI-Licenses/$dependency-LICENSE.txt"
    if [[ -f "$checkout/NOTICE.txt" ]]; then
        /usr/bin/install -m 0644 "$checkout/NOTICE.txt" "$app/Contents/Resources/CLI-Licenses/$dependency-NOTICE.txt"
    fi
done
cp licenses/swift-cmark-COPYING.txt "$app/Contents/Resources/"
cp licenses/Unicode-License-V3.txt Sources/UtilityCore/Resources/confusables.txt "$app/Contents/Resources/"
cp licenses/EFF-Wordlist-Attribution.txt Sources/UtilityCore/Resources/eff_large_wordlist.txt "$app/Contents/Resources/"
cp licenses/libarchive-ABI.txt "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacUtilityKit</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>Mac Utility Kit</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PDF Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
    <key>CFBundleShortVersionString</key><string>$release_version</string>
    <key>CFBundleVersion</key><string>$build_version</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPhotoLibraryUsageDescription</key><string>Organize selected downloaded images into Photos albums.</string>
    <key>NSMicrophoneUsageDescription</key><string>Record audio with the microphone you select.</string>
</dict>
</plist>
PLIST
plist="$app/Contents/Info.plist"
/usr/bin/plutil -insert NSServices -xml "$(cat scripts/finder-services.plist)" "$plist"
add_release_feed() {
    local feed="$1" key="$2" feed_name="$3" key_name="$4"
    if [[ -z "$feed" && -z "$key" ]]; then return; fi
    if [[ "$feed" != https://?* || ! "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        printf 'Invalid release configuration for %s and %s.\n' "$feed_name" "$key_name" >&2
        exit 2
    fi
    /usr/bin/plutil -insert "$feed_name" -string "$feed" "$plist"
    /usr/bin/plutil -insert "$key_name" -string "$key" "$plist"
}
add_release_feed "${MUK_VIDEO_ENGINE_FEED:-}" "${MUK_VIDEO_ENGINE_PUBLIC_KEY:-}" MUKVideoEngineFeed MUKVideoEnginePublicKey
add_release_feed "${MUK_APPCAST_URL:-}" "${MUK_APPCAST_PUBLIC_KEY:-}" SUFeedURL SUPublicEDKey

sparkle_artifact=".build/artifacts/sparkle/Sparkle"
framework="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle_artifact/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
cp "$sparkle_artifact/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
identity="${MUK_CODESIGN_IDENTITY:--}"
signing=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
    signing+=(--options runtime --timestamp)
fi
sparkle_version="$framework/Versions/Current"
for component in "$sparkle_version"/XPCServices/*.xpc "$sparkle_version/Updater.app" "$sparkle_version/Autoupdate"; do
    if [[ -e "$component" ]]; then codesign "${signing[@]}" --preserve-metadata=entitlements "$component"; fi
done
codesign "${signing[@]}" "$framework"
codesign "${signing[@]}" "$app/Contents/MacOS/muk"
codesign "${signing[@]}" "$app"
# Refresh the icon when a local build replaces an already registered app in place.
touch "$app"
launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$launch_services" ]]; then
    "$launch_services" -f "$PWD/$app" >/dev/null 2>&1 || true
fi
printf '%s\n' "$app"
