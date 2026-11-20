"""Compare the packaged CLI catalog with the roadmap inventory."""

import json
import re
import subprocess
import sys
from pathlib import Path


def check(binary):
    inventory_file = Path(__file__).resolve().parent.parent / "docs" / "feature-inventory.md"
    inventory = re.findall(r"^- \*\*(.+?)\*\*", inventory_file.read_text(encoding="utf-8"), re.MULTILINE)
    catalog = json.loads(subprocess.check_output([binary, "catalog"], timeout=10))
    titles = [entry["title"] for entry in catalog]
    if len(titles) != 102 or len(inventory) != 102:
        raise SystemExit(f"Expected 102 tools. Found {len(titles)} in the catalog and {len(inventory)} in the inventory.")
    if len({entry["id"] for entry in catalog}) != len(catalog):
        raise SystemExit("The packaged catalog contains duplicate tool IDs.")
    if sorted(titles) != sorted(inventory):
        raise SystemExit("The packaged catalog and roadmap inventory differ.")
    if not all(
        isinstance(entry.get("inputTypes"), list)
        and all(isinstance(kind, str) and kind for kind in entry["inputTypes"])
        for entry in catalog
    ):
        raise SystemExit("The packaged catalog is missing accepted input type identifiers.")
    expected_cli = {
        "resizeImages": "resize-images",
        "mergePDFs": "merge-pdfs",
        "mediaInfo": "media-info",
        "hashGenerator": "hash",
        "jsonFormatter": "format-json",
    }
    expected_mcp = {
        "jsonFormatter": "format-json",
        "wordCounter": "word-count",
        "cleanLinks": "clean-link",
    }
    for entry in catalog:
        tool = entry["id"]
        expected = {}
        if tool in expected_cli:
            expected["cliCommand"] = expected_cli[tool]
        if tool in expected_mcp:
            expected["mcp"] = {"capability": expected_mcp[tool], "requiresExplicitOptIn": True}
        if entry.get("automation") != expected:
            raise SystemExit(f"Incorrect automation metadata for {tool}: {entry.get('automation')}")
    for command in expected_cli.values():
        help_text = subprocess.check_output([binary, command, "--help"], timeout=10, text=True)
        if f"USAGE: muk {command}" not in help_text:
            raise SystemExit(f"The catalog lists an unregistered CLI command: {command}.")
    print("The packaged catalog matches all 102 roadmap tools.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Pass the path to the packaged muk binary.")
    check(sys.argv[1])
