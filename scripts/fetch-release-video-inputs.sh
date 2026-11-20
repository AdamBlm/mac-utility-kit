#!/bin/bash
set -euo pipefail
if [[ $# != 4 ]]; then
    printf 'Usage: %s <arm64|x86_64> <yt-dlp tag> <Deno tag> <new output directory>\n' "$0" >&2
    exit 2
fi
case "$1" in
    arm64) deno_arch=aarch64 ;;
    x86_64) deno_arch=x86_64 ;;
    *) printf 'Unsupported macOS architecture.\n' >&2; exit 2 ;;
esac
yt_tag="$2"
deno_tag="$3"
if [[ ! "$yt_tag" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ||
      ! "$deno_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || -e "$4" ]]; then
    printf 'Provide stable release tags and a new output directory.\n' >&2
    exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/muk-video-inputs.XXXXXX")"
trap 'rm -rf "$work"' EXIT
download() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --max-time 240 --max-filesize 250000000 --output "$2" "$1"
}
yt_release="https://github.com/yt-dlp/yt-dlp/releases/download/$yt_tag"
for asset in yt-dlp_macos SHA2-256SUMS SHA2-256SUMS.sig; do
    download "$yt_release/$asset" "$work/$asset"
done
download "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$yt_tag/public.key" "$work/yt-dlp.key"
mkdir -m 700 "$work/gnupg"
yt_signing_fingerprint=AC0CBBE6848D6A873464AF4E57CF65933B5A7581
fingerprint="$(gpg --homedir "$work/gnupg" --batch --with-colons --show-keys "$work/yt-dlp.key" |
    awk -F: '$1 == "fpr" && !fingerprint { fingerprint = $10 } END { print fingerprint }')"
if [[ "$fingerprint" != "$yt_signing_fingerprint" ]]; then
    printf 'The upstream yt-dlp signing key fingerprint changed.\n' >&2
    exit 1
fi
gpg --homedir "$work/gnupg" --batch --import "$work/yt-dlp.key"
gpg --homedir "$work/gnupg" --batch --status-fd 1 \
    --verify "$work/SHA2-256SUMS.sig" "$work/SHA2-256SUMS" > "$work/signature-status"
awk -v fingerprint="$yt_signing_fingerprint" '
    $2 == "VALIDSIG" && ($3 == fingerprint || $NF == fingerprint) { verified = 1 }
    END { exit !verified }
' "$work/signature-status"
awk '$2 == "yt-dlp_macos" || $2 == "*yt-dlp_macos"' "$work/SHA2-256SUMS" > "$work/yt-dlp.sha256"
test -s "$work/yt-dlp.sha256"
(cd "$work" && shasum -a 256 -c yt-dlp.sha256)

deno_release="https://github.com/denoland/deno/releases/download/$deno_tag"
deno_asset="deno-$deno_arch-apple-darwin.zip"
download "$deno_release/$deno_asset" "$work/deno.zip"
download "$deno_release/$deno_asset.sha256sum" "$work/deno.zip.sha256sum"
(cd "$work" && printf '%s  deno.zip\n' "$(awk 'NR == 1 { print $1 }' deno.zip.sha256sum)" | shasum -a 256 -c)
test "$(zipinfo -1 "$work/deno.zip")" = deno
unzip -p "$work/deno.zip" deno > "$work/deno"

mkdir "$4"
install -m 0755 "$work/yt-dlp_macos" "$4/yt-dlp"
install -m 0755 "$work/deno" "$4/deno"
printf '%s\n%s\n' "$yt_release/yt-dlp_macos" "$deno_release/$deno_asset" > "$4/upstream-artifacts.txt"
