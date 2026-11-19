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
    print("The packaged catalog matches all 102 roadmap tools.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Pass the path to the packaged muk binary.")
    check(sys.argv[1])
