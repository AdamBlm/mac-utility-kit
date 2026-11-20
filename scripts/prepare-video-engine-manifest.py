"""Build a manifest from release-approved, post-signing macOS executables."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit

TOOLS = {"yt-dlp", "deno", "ffmpeg", "ffprobe"}
FFMPEG_ENCODERS = {"libx264", "libx265", "libvpx-vp9", "libopus", "libvorbis", "libmp3lame",
                   "h264_videotoolbox", "hevc_videotoolbox"}


def https(value):
    address = urlsplit(value)
    if address.scheme != "https" or not address.hostname or address.username is not None:
        raise ValueError(f"Expected an HTTPS release URL: {value}")
    return value


def command(*arguments):
    return subprocess.check_output(arguments, text=True, timeout=90, stderr=subprocess.STDOUT).strip()


def inspected_artifacts(root, arch, records):
    if set(records) != TOOLS:
        raise ValueError(f"{arch}: expected {', '.join(sorted(TOOLS))}")
    artifacts = []
    for name, record in sorted(records.items()):
        path = (root / arch / name).resolve(strict=True)
        minimum = record["minimumMacOS"]
        if type(minimum) is not int or minimum < 15:
            raise ValueError(f"{name}: minimumMacOS must be the supported macOS major version")
        version = record["version"]
        if not isinstance(version, str) or not version.strip():
            raise ValueError(f"{path}: expected a version")
        if arch not in command("/usr/bin/lipo", "-archs", path).split():
            raise ValueError(f"{path} does not contain {arch}")
        command("/usr/bin/codesign", "--verify", "--strict", path)
        build = command("/usr/bin/xcrun", "vtool", "-arch", arch, "-show-build", path)
        targets = re.findall(r"(?m)^ +minos (\d+)(?:\.(\d+))?(?:\.(\d+))?$", build)
        if not targets:
            targets = re.findall(
                r"LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+)(?:\.(\d+))?(?:\.(\d+))?", build
            )
        if not targets or max(tuple(int(part or 0) for part in target) for target in targets) > (minimum, 0, 0):
            raise ValueError(f"{path}: deployment target exceeds macOS {minimum}.0")
        libraries = command("/usr/bin/otool", "-arch", arch, "-L", path).splitlines()[1:]
        if any(not line.lstrip().startswith(("/usr/lib/", "/System/Library/")) for line in libraries):
            raise ValueError(f"{path} references a non-system dynamic library")
        hasher = hashlib.sha256()
        with path.open("rb") as binary:
            for block in iter(lambda: binary.read(1024 * 1024), b""):
                hasher.update(block)
        digest = hasher.hexdigest()
        size = path.stat().st_size
        if not 1 <= size <= 250_000_000:
            raise ValueError(f"{path}: invalid artifact size")
        if digest != record["sha256"]:
            raise ValueError(f"{path}: SHA-256 differs from the reviewed artifact")
        artifacts.append({"name": name, "version": version, "url": https(record["url"]),
                          "notices": https(record["notices"]), "bytes": size, "sha256": digest,
                          "minimumMacOS": minimum})
        if name in {"ffmpeg", "ffprobe", "yt-dlp"} or "source" in record:
            artifacts[-1]["source"] = https(record["source"])
        if name.startswith("ff"):
            configuration = command("/usr/bin/arch", f"-{arch}", path, "-buildconf")
            if "--enable-nonfree" in configuration or "--enable-gpl" not in configuration:
                raise ValueError(f"{path} requires a redistributable GPL configuration")
            if name == "ffmpeg":
                encoders = command("/usr/bin/arch", f"-{arch}", path, "-hide_banner", "-encoders")
                filters = command("/usr/bin/arch", f"-{arch}", path, "-hide_banner", "-filters")
                decoders = command("/usr/bin/arch", f"-{arch}", path, "-hide_banner", "-decoders")
                devices = command("/usr/bin/arch", f"-{arch}", path, "-hide_banner", "-devices")
                if "png" not in decoders.split() or "lavfi" not in devices.split():
                    raise ValueError(f"{path}: missing PNG decoding or lavfi input")
                missing = FFMPEG_ENCODERS - set(encoders.split())
                if missing or not re.search(r"\bsubtitles\b", filters):
                    raise ValueError(f"{path}: missing required encoders or subtitle filter ({sorted(missing)})")
    if records["ffmpeg"]["version"] != records["ffprobe"]["version"]:
        raise ValueError("FFmpeg and FFprobe must have the same release version")
    return artifacts


def main():
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("metadata", type=Path)
    arguments.add_argument("artifact_directory", type=Path)
    arguments.add_argument("output", type=Path)
    options = arguments.parse_args()
    metadata = json.loads(options.metadata.read_bytes())
    revision = metadata["revision"]
    if type(revision) is not int or revision <= 0:
        raise ValueError("Expected a positive, monotonically increasing engine release revision")
    platforms = metadata["platforms"]
    if not platforms or set(platforms) - {"arm64", "x86_64"}:
        raise ValueError("Provide arm64 and/or x86_64 package metadata")
    packages = {arch: inspected_artifacts(options.artifact_directory, arch, records)
                for arch, records in platforms.items()}
    options.output.write_text(json.dumps({"schema": 1, "revision": revision, "platforms": packages},
                                         sort_keys=True, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
