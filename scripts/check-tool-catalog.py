"""Compare the packaged CLI catalog with the roadmap inventory."""

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def check(binary):
    inventory_file = Path(__file__).resolve().parent.parent / "docs" / "feature-inventory.md"
    inventory = re.findall(r"^- \*\*(.+?)\*\*", inventory_file.read_text(encoding="utf-8"), re.MULTILINE)
    catalog = json.loads(subprocess.check_output([binary, "catalog"], timeout=10))
    titles = [entry["title"] for entry in catalog]
    if len(titles) != 105 or len(inventory) != 105:
        raise SystemExit(f"Expected 105 tools. Found {len(titles)} in the catalog and {len(inventory)} in the inventory.")
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
        "csvJSON": "convert-table",
    }
    expected_mcp = {
        "jsonFormatter": "format-json",
        "wordCounter": "word-count",
        "cleanLinks": "clean-link",
    }
    single_pdf = {
        "splitPDF", "organizePDF", "deletePDFPages", "extractPDFPages",
        "pdfToImages", "signPDF", "cropPDF", "redactPDF",
    }
    office_pdf = {"wordToPDF", "powerPointToPDF", "excelToPDF"}
    file_jobs = {"resizeImages", "mergePDFs", "mediaInfo"}
    for entry in catalog:
        tool = entry["id"]
        if entry.get("workspaceStatus") != "registered":
            raise SystemExit(f"Incorrect workspace registration metadata for {tool}.")
        expected = {}
        if tool in expected_cli:
            expected["cliCommand"] = expected_cli[tool]
        if tool in expected_mcp:
            expected["mcp"] = {"capability": expected_mcp[tool], "requiresExplicitOptIn": True}
        if entry.get("automation") != expected:
            raise SystemExit(f"Incorrect automation metadata for {tool}: {entry.get('automation')}")
        prerequisites = []
        if tool in single_pdf:
            prerequisites.append({"id": "singlePDF", "surface": "app"})
        if tool in office_pdf:
            prerequisites.append({"id": "libreOffice", "surface": "app"})
        if tool in {"addPassword", "removePassword"}:
            prerequisites.append({"id": "externalExecutable", "surface": "app",
                                  "executable": "qpdf", "operations": ["export"]})
        if tool == "downloadVideo":
            prerequisites.append({"id": "externalExecutable", "surface": "app",
                                  "executable": "yt-dlp", "operations": ["inspect", "download"]})
        if tool in file_jobs:
            prerequisites.append({"id": "existingDestinationDirectory", "surface": "cli"})
        if tool in expected_mcp:
            prerequisites.append({"id": "explicitAllow", "surface": "mcp"})
        if entry.get("prerequisites") != prerequisites:
            raise SystemExit(f"Incorrect prerequisites for {tool}: {entry.get('prerequisites')}")
    for command in expected_cli.values():
        help_text = subprocess.check_output([binary, command, "--help"], timeout=10, text=True)
        if f"USAGE: muk {command}" not in help_text:
            raise SystemExit(f"The catalog lists an unregistered CLI command: {command}.")
    with tempfile.TemporaryDirectory() as directory:
        missing_destination = str(Path(directory) / "missing")
        for tool in file_jobs:
            result = subprocess.run(
                [binary, expected_cli[tool], "--destination", missing_destination, "unused-input"],
                timeout=10, capture_output=True, text=True,
            )
            if result.returncode == 0 or "Choose an existing destination folder." not in result.stderr:
                raise SystemExit(f"{tool} did not enforce its cataloged destination prerequisite.")
    check_table_conversion(binary)
    print("The packaged catalog matches all 105 roadmap tools.")


def check_table_conversion(binary):
    def convert(*args, content=b""):
        return subprocess.run([binary, "convert-table", *args], input=content, capture_output=True, timeout=10)

    csv = 'id;note\r\n001;"a;b\nété"\r\n002;\r\n'.encode()
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "input file.csv"
        source.write_bytes(csv)
        encoded = convert("csv-to-json", str(source), "--delimiter", "auto")
        assert source.read_bytes() == csv
    assert encoded.returncode == 0 and not encoded.stderr, encoded.stderr
    assert json.loads(encoded.stdout) == [{"id": "001", "note": "a;b\nété"}, {"id": "002", "note": ""}]
    bom = "\ufeff".encode()
    first_field = convert("csv-to-json", content=bom * 2 + b"code\n001\n")
    assert first_field.returncode == 0 and json.loads(first_field.stdout) == [{"\ufeffcode": "001"}]
    decoded = convert("json-to-csv", "--delimiter", "semicolon", content=encoded.stdout)
    assert decoded.returncode == 0 and decoded.stdout == csv.replace(b"002;\r\n", b'002;""\r\n'), decoded.stderr
    markdown = convert("csv-to-markdown", "--no-headers", content=b"001,a|b\n")
    assert markdown.returncode == 0 and b"Column&#32;1" in markdown.stdout and b"a&#124;b" in markdown.stdout
    invalid = convert("csv-to-json", content=b"a,b\n1\n")
    assert invalid.returncode != 0 and not invalid.stdout and b"Row 2" in invalid.stderr, invalid.stderr
    no_delimiter = convert("json-to-csv", "--delimiter", "auto", content=b"[]")
    assert no_delimiter.returncode != 0 and b"explicit delimiter" in no_delimiter.stderr
    ambiguous = convert("csv-to-json", "--delimiter", "auto", content=b"a,b;c\n1,2;3\n")
    assert ambiguous.returncode != 0 and b"Several delimiters fit" in ambiguous.stderr
    non_utf8 = convert("csv-to-json", content=b"\xff")
    assert non_utf8.returncode != 0 and b"UTF-8" in non_utf8.stderr


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Pass the path to the packaged muk binary.")
    check(sys.argv[1])
