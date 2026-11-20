#!/bin/bash
set -euo pipefail
if [[ $# != 1 || -e "$1" ]]; then
    printf 'Pass a new output directory for the FFmpeg release candidate.\n' >&2
    exit 2
fi

if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
    printf 'Use a Python 3.10 or newer on PATH for the pinned vcpkg tools.\n' >&2
    exit 2
fi

pin=74f5ea45ca78988784b810ad9bbb148ea7ff76d8
deployment_target=15.0
case "$(uname -m)" in
    arm64) triplet=arm64-osx ;;
    x86_64) triplet=x64-osx ;;
    *) printf 'Unsupported build architecture.\n' >&2; exit 2 ;;
esac

mkdir -p "$1"
output="$(cd "$1" && pwd -P)"
git init -q "$output/vcpkg"
git -C "$output/vcpkg" fetch --quiet --depth 1 https://github.com/microsoft/vcpkg.git "$pin"
git -C "$output/vcpkg" checkout --quiet --detach FETCH_HEAD
test "$(git -C "$output/vcpkg" rev-parse HEAD)" = "$pin"

export VCPKG_DISABLE_METRICS=1
export VCPKG_DOWNLOADS="$output/downloads"
export VCPKG_BINARY_SOURCES=clear
mkdir -p "$VCPKG_DOWNLOADS"
triplet_file="$output/vcpkg/triplets/$triplet.cmake"
printf '\nset(VCPKG_OSX_DEPLOYMENT_TARGET %s)\n' "$deployment_target" >> "$triplet_file"
(
    cd "$output/vcpkg"
    ./bootstrap-vcpkg.sh -disableMetrics
    ./vcpkg install --classic --no-print-usage \
        "ffmpeg[core,ffmpeg,ffprobe,gpl,ass,avdevice,drawtext,fontconfig,mp3lame,network,opus,swresample,swscale,vorbis,vpx,x264,x265,zlib]:$triplet"
)
installed="$output/vcpkg/installed/$triplet"
mkdir "$output/bin" "$output/notices"
for tool in ffmpeg ffprobe; do
    install -m 0755 "$installed/tools/ffmpeg/$tool" "$output/bin/$tool"
    "$output/bin/$tool" -buildconf > "$output/$tool-buildconf.txt" 2>&1
    if grep -q -- --enable-nonfree "$output/$tool-buildconf.txt" ||
        ! grep -q -- --enable-gpl "$output/$tool-buildconf.txt"; then
        printf 'Unexpected FFmpeg license configuration in %s.\n' "$tool" >&2
        exit 1
    fi
done
for notice in "$installed"/share/*/copyright; do
    name="$(basename "$(dirname "$notice")")"
    cp "$notice" "$output/notices/$name.txt"
done
git -C "$output/vcpkg" diff > "$output/vcpkg-deployment-target.patch"
cp "$output/vcpkg/installed/vcpkg/status" "$output/vcpkg-installed-packages.txt"
printf '%s\n' "$pin" > "$output/vcpkg-revision.txt"
printf 'Candidate binaries, notices, and build inputs are in %s\n' "$output"
