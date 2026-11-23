"""Compare the packaged CLI catalog with the roadmap inventory."""

import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import zlib
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
    check_resize_batch(binary)
    check_merge_pdf_batch(binary)
    check_media_info_batch(binary)
    check_hash_batch(binary)
    check_table_conversion(binary)
    check_json_formatting(binary)
    print("The packaged catalog matches all 105 roadmap tools.")


def write_solid_png(path, width, height, pixel):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    rows = (b"\x00" + pixel * width) * height
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def check_resize_batch(binary):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        landscape = root / "landscape" / "same name.png"
        portrait = root / "portrait" / landscape.name
        for source in (landscape, portrait):
            source.parent.mkdir()
        write_solid_png(landscape, 96, 48, b"\xff\x00\x00")
        write_solid_png(portrait, 30, 60, b"\x00\x00\xff")
        corrupt = root / "corrupt.png"
        corrupt.write_bytes(b"not an image")
        destination = root / "outputs"
        destination.mkdir()
        fifo = root / "unconnected.png"
        os.mkfifo(fifo)
        sources = [landscape, corrupt, portrait]
        originals = [source.read_bytes() for source in sources]

        result = subprocess.run(
            [binary, "resize-images", "--destination", str(destination),
             "--longest-edge", "40", *map(str, [landscape, fifo, corrupt, portrait])],
            capture_output=True, timeout=15,
        )
        assert result.returncode == 1, (result.stdout, result.stderr)
        report = json.loads(result.stdout)
        assert len(report["failures"]) == 2, report
        assert fifo.name in report["failures"][0] and corrupt.name in report["failures"][1], report
        outputs = list(map(Path, report["outputs"]))
        assert len(outputs) == 2 and outputs[0] != outputs[1], report
        for output, dimensions in zip(outputs, [(40, 20), (20, 40)]):
            assert output.parent.parent == destination, output
            image = output.read_bytes()
            assert image[:8] == b"\x89PNG\r\n\x1a\n", output
            assert struct.unpack(">II", image[16:24]) == dimensions, output
        assert set(destination.glob("*/*")) == set(outputs), report
        assert not list(destination.glob(".MacUtilityKit-*")), report
        assert [source.read_bytes() for source in sources] == originals


def check_merge_pdf_batch(binary):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        wide, tall = root / "wide.png", root / "tall.png"
        write_solid_png(wide, 96, 48, b"\xff\x00\x00")
        write_solid_png(tall, 30, 60, b"\x00\x00\xff")
        corrupt = root / "corrupt.pdf"
        corrupt.write_bytes(b"not a PDF")

        def merge(destination, *arguments):
            destination.mkdir(exist_ok=True)
            return subprocess.run(
                [binary, "merge-pdfs", "--destination", str(destination), *map(str, arguments)],
                capture_output=True, timeout=15,
            )

        seed = merge(root / "seed", wide, tall)
        assert seed.returncode == 0, (seed.stdout, seed.stderr)
        source, = map(Path, json.loads(seed.stdout)["outputs"])
        originals = {path: path.read_bytes() for path in (wide, tall, corrupt, source)}
        destination = root / "outputs"

        for ranges in [[], ["--pages", "3", "--pages", "none", "--pages", "1"]]:
            failed = merge(destination, *ranges, source, corrupt, tall)
            assert failed.returncode != 0 and not list(destination.iterdir()), (failed.stdout, failed.stderr)

        selected = merge(destination, "--pages", "2,1", "--pages", "none", "--pages", "1",
                         "--name", "Selected.pdf", source, corrupt, wide)
        assert selected.returncode == 0, (selected.stdout, selected.stderr)
        report = json.loads(selected.stdout)
        output, = map(Path, report["outputs"])
        assert output.name == "Selected.pdf" and output.read_bytes().startswith(b"%PDF-"), report
        assert not report["failures"] and set(destination.glob("*/*")) == {output}, report
        assert not list(destination.glob(".MacUtilityKit-*")), report
        assert all(path.read_bytes() == original for path, original in originals.items())
        if qpdf := os.environ.get("MAC_UTILITY_QPDF_TEST"):
            details = json.loads(subprocess.check_output([qpdf, "--json", str(output)], timeout=15))
            sizes = [
                [(image["width"], image["height"]) for image in page["images"]]
                for page in details["pages"]
            ]
            assert sizes == [[(30, 60)], [(96, 48)], [(96, 48)]], sizes


def check_media_info_batch(binary):
    ffmpeg = os.environ.get("MAC_UTILITY_FFMPEG_TEST")
    ffprobe = os.environ.get("MAC_UTILITY_FFPROBE_TEST")
    if not ffmpeg or not ffprobe:
        return

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        probe_link = root / "ffprobe link"
        probe_link.symlink_to(Path(ffprobe).resolve(strict=True))
        video = root / "clip.webm"
        audio = root / "tone.wav"
        corrupt = root / "corrupt.webm"
        corrupt.write_bytes(b"not media")
        destination = root / "outputs"
        destination.mkdir()

        for source, codec, path in [
            ("testsrc2=size=160x90:rate=24", "libvpx-vp9", video),
            ("sine=frequency=440:sample_rate=44100", "pcm_s16le", audio),
        ]:
            subprocess.run(
                [ffmpeg, "-v", "error", "-f", "lavfi", "-i", source, "-t", "0.25",
                 "-c", codec, str(path)],
                check=True, capture_output=True, timeout=15,
            )

        result = subprocess.run(
            [binary, "media-info", "--destination", str(destination), "--ffprobe", str(probe_link),
             str(video), str(corrupt), str(audio)],
            capture_output=True, timeout=15,
        )
        assert result.returncode == 1, (result.stdout, result.stderr)
        report = json.loads(result.stdout)
        assert len(report["failures"]) == 1 and corrupt.name in report["failures"][0], report
        assert len(report["outputs"]) == 2, report
        video_report, audio_report = [
            json.loads(Path(output).read_bytes()) for output in report["outputs"]
        ]
        video_stream, = video_report["streams"]
        audio_stream, = audio_report["streams"]
        assert video_stream["codec_name"] == "vp9", video_stream
        assert (video_stream["width"], video_stream["height"]) == (160, 90), video_stream
        assert audio_stream["codec_name"] == "pcm_s16le", audio_stream
        assert audio_stream["sample_rate"] == "44100", audio_stream
        assert video_report["format"]["filename"] == video.name, video_report
        assert audio_report["format"]["filename"] == audio.name, audio_report


def check_hash_batch(binary):
    binary = str(Path(binary).resolve())
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        ordinary = "a b.txt"
        escaped = "back\\slash\nline\rbreak"
        missing = "missing.txt"
        (root / ordinary).write_bytes(b"")
        (root / escaped).write_bytes(b"abc")
        result = subprocess.run(
            [binary, "hash", ordinary, missing, escaped],
            cwd=root, capture_output=True, timeout=10,
        )
        assert result.returncode == 1 and missing.encode() in result.stderr, result.stderr
        first = hashlib.sha256(b"").hexdigest()
        last = hashlib.sha256(b"abc").hexdigest()
        expected = f"{first}  {ordinary}\n\\{last}  back\\\\slash\\nline\\rbreak\n"
        assert result.stdout == expected.encode(), result.stdout


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


def check_json_formatting(binary):
    content = b'{"z":9007199254740993,"a":-0.000E+100,"z":2}'
    expected = b'{"a":-0.000E+100,"z":9007199254740993,"z":2}\n'
    command = [binary, "format-json", "--indentation", "minified", "--sort-keys"]
    with tempfile.TemporaryDirectory() as directory:
        folder = Path(directory)
        source = folder / "input file.json"
        source.write_bytes(content)
        for arguments, stdin in (([source], b""), (["-"], content)):
            result = subprocess.run(command + arguments, input=stdin, capture_output=True, timeout=10)
            assert result.returncode == 0 and result.stdout == expected, result
            assert b"Duplicate key kept:" in result.stderr, result.stderr
        assert source.read_bytes() == content

        fifo = folder / "unconnected.json"
        os.mkfifo(fifo)
        for tool, args in (("format-json", []), ("convert-table", ["json-to-csv"])):
            result = subprocess.run([binary, tool, *args, fifo], capture_output=True, timeout=5)
            assert result.returncode != 0 and not result.stdout, result
            assert b"Choose a local regular file" in result.stderr, result.stderr


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Pass the path to the packaged muk binary.")
    check(sys.argv[1])
