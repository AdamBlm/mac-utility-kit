"""Verify the packaged MCP server over its actual standard I/O transport."""

import json
import os
import select
import subprocess
import sys
import time


def check(binary):
    disabled = subprocess.run([binary, "mcp"], capture_output=True, timeout=10)
    assert disabled.returncode != 0 and b"Use --allow" in disabled.stderr, (
        "MCP did not reject startup without an explicit allow list"
    )

    catalog = json.loads(subprocess.check_output([binary, "catalog"], timeout=10))
    mcp = {entry["id"]: entry["automation"]["mcp"]
           for entry in catalog if "mcp" in entry["automation"]}
    selected = {mcp[tool]["capability"] for tool in ("jsonFormatter", "cleanLinks")}
    assert set(mcp) == {"jsonFormatter", "wordCounter", "cleanLinks"}
    assert all(entry["requiresExplicitOptIn"] is True for entry in mcp.values())
    command = [binary, "mcp"]
    for capability in sorted(selected):
        command.extend(["--allow", capability])
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as server:
        received = bytearray()

        def send(method, params=None, request_id=None):
            request = {"jsonrpc": "2.0", "method": method}
            if params is not None:
                request["params"] = params
            if request_id is not None:
                request["id"] = request_id
            server.stdin.write(json.dumps(request).encode() + b"\n")
            server.stdin.flush()
            if request_id is None:
                return None

            deadline = time.monotonic() + 10
            while b"\n" not in received:
                timeout = deadline - time.monotonic()
                assert timeout > 0 and select.select([server.stdout], [], [], timeout)[0], f"No response to {method}"
                chunk = os.read(server.stdout.fileno(), 65536)
                assert chunk, f"MCP stopped before responding to {method}"
                received.extend(chunk)
                assert len(received) <= 1_048_576, f"Oversized response to {method}"
            end = received.index(b"\n")
            response = json.loads(received[:end])
            del received[:end + 1]
            assert response.get("id") == request_id, f"Unexpected response to {method}: {response}"
            return response["result"]

        def call(tool, arguments, request_id):
            return send("tools/call", {"name": tool, "arguments": arguments}, request_id)

        try:
            initialized = send("initialize", {
                "protocolVersion": "2024-11-05",
                "clientInfo": {"name": "Mac Utility Kit fixture", "version": "1"},
                "capabilities": {},
            }, 1)
            assert initialized["serverInfo"]["name"] == "Mac Utility Kit"
            send("notifications/initialized")
            listing = send("tools/list", request_id=2)
            assert {tool["name"] for tool in listing["tools"]} == selected
            for tool in listing["tools"]:
                assert tool["inputSchema"] == {
                    "type": "object",
                    "required": ["text"],
                    "properties": {"text": {"type": "string"}},
                    "additionalProperties": False,
                }, f"Unexpected input schema for {tool['name']}"

            formatted = call("format-json", {"text": '{"n":9007199254740993,"b":-0.000E+100}'}, 3)
            assert not formatted["isError"]
            assert formatted["content"] == [
                {"type": "text", "text": '{\n  "b": -0.000E+100,\n  "n": 9007199254740993\n}'}
            ]
            clean = call("clean-link", {"text": "https://example.test/?utm_source=fixture&keep=1#section"}, 4)
            assert not clean["isError"] and clean["content"][0]["text"] == "https://example.test/?keep=1#section"
            assert call("word-count", {"text": "two words"}, 5)["isError"]
            assert call("format-json", {"text": "{}", "extra": ""}, 6)["isError"]
            assert call("format-json", {}, 7)["isError"]
            assert call("format-json", {"text": 42}, 8)["isError"]
            duplicate = call("format-json", {"text": '{\n  "n": 9007199254740993,\n  "\\u006e": 2\n}'}, 9)
            assert not duplicate["isError"]
            assert len(duplicate["content"]) == 2 and all(block["type"] == "text" for block in duplicate["content"])
            assert duplicate["content"][0]["text"] == '{\n  "n": 9007199254740993,\n  "\\u006e": 2\n}'
            warning = duplicate["content"][1]["text"]
            assert "Duplicate keys preserved (1)" in warning and '"n" at line 3, column 3' in warning
            invalid = call("format-json", {"text": '{\n  "n": #\n}'}, 10)
            assert invalid["isError"] and len(invalid["content"]) == 1
            assert "line 2, column 8" in invalid["content"][0]["text"]
        finally:
            server.stdin.close()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        assert server.returncode == 0, "MCP did not exit cleanly after closing input"


if __name__ == "__main__":
    check(sys.argv[1])
