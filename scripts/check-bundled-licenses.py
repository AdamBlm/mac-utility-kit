"""Check that the built app carries the notices from its pinned dependencies."""

import json
from pathlib import Path
import sys

repository = Path(__file__).resolve().parent.parent
resources = Path(sys.argv[1]) / "Contents" / "Resources"
checkouts = repository / ".build" / "checkouts"

def verify(source, installed):
    if not installed.is_file() or source.read_bytes() != installed.read_bytes():
        raise SystemExit(f"Missing or mismatched bundled notice: {installed.name}")

pins = json.loads((repository / "Package.resolved").read_text())["pins"]
for pin in pins:
    identity = pin["identity"]
    checkout = checkouts / ("KeyboardShortcuts" if identity == "keyboardshortcuts" else identity)
    if identity == "keyboardshortcuts":
        verify(checkout / "license", resources / "KeyboardShortcuts-LICENSE.txt")
    elif identity == "swift-cmark":
        verify(checkout / "COPYING", resources / "swift-cmark-COPYING.txt")
    else:
        cli = resources / "CLI-Licenses"
        source = {"eventsource": "LICENSE.md", "swift-sdk": "LICENSE", "swift-subprocess": "LICENSE"}.get(
            identity, "LICENSE.txt"
        )
        verify(checkout / source, cli / f"{identity}-LICENSE.txt")
        notice = checkout / "NOTICE.txt"
        if notice.is_file():
            verify(notice, cli / f"{identity}-NOTICE.txt")

for notice in ("Unicode-License-V3.txt", "EFF-Wordlist-Attribution.txt", "libarchive-ABI.txt"):
    verify(repository / "licenses" / notice, resources / notice)

print(f"Verified bundled licenses for {len(pins)} pinned packages and the local attribution files.")
