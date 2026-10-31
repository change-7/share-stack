import argparse
import json
from pathlib import Path
import re
import selectors
import subprocess
import tempfile
import time


class Client:
    def __init__(self, executable):
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen([str(executable), "--mcp"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.sequence = 0
        self.maximum_latency = 0
        result = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                        "clientInfo": {"name": "sharestack-verifier", "version": "1"}})
        assert result["result"]["capabilities"]["tools"] is not None
        self.notify("notifications/initialized")

    def notify(self, method):
        self.process.stdin.write((json.dumps({"jsonrpc": "2.0", "method": method}) + "\n").encode())
        self.process.stdin.flush()

    def rpc(self, method, params=None):
        self.sequence += 1
        message = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params or {}}
        started = time.monotonic()
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        self.process.stdin.flush()
        assert self.selector.select(9.5), f"No response within 9.5 seconds: {method}"
        line = self.process.stdout.readline()
        assert line, f"MCP exited while calling {method}"
        response = json.loads(line)
        latency = time.monotonic() - started
        self.maximum_latency = max(self.maximum_latency, latency)
        assert latency < 10 and response["jsonrpc"] == "2.0" and response["id"] == self.sequence
        return response

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert not self.process.stdout.read(), "Unexpected stdout after EOF"
        self.selector.close()
        self.stderr.close()


EXPECTED_TOOLS = {
    "list_workspaces", "list_workspace_entries", "get_workspace_file_info", "read_workspace_file",
    "list_workspace_changes", "apply_workspace_patch", "create_workspace_text_file",
    "list_shared_files", "get_shared_file_info", "read_shared_file",
    "receive_exchange_text_file", "receive_text_file", "get_job", "cancel_job",
}


def main():
    parser = argparse.ArgumentParser(description="Check the bundled MCP contract without touching GUI data.")
    parser.add_argument("--bundle", default="ShareStackMac.app")
    args = parser.parse_args()
    bundle = Path(args.bundle).resolve()
    manifest = json.loads((bundle / "Contents/Resources/linkdeck.json").read_text(encoding="utf-8"))
    client = Client(bundle / "Contents/MacOS/ShareStackMac")
    try:
        tools = []
        params = {}
        cursors = set()
        while True:
            page = client.rpc("tools/list", params)["result"]
            tools.extend(page["tools"])
            cursor = page.get("nextCursor")
            if cursor is None:
                break
            assert cursor not in cursors and len(cursors) < 20, "Repeated or excessive tools cursor"
            cursors.add(cursor)
            params = {"cursor": cursor}
        names = [tool["name"] for tool in tools]
        assert len(names) == len(set(names)), f"Duplicate MCP tools: {names}"
        declared = manifest["tools"]
        assert len(declared) == len(set(declared)), "Duplicate manifest tools"
        assert set(declared) == set(names), (
            f"Manifest/MCP mismatch: declared only={sorted(set(declared) - set(names))}; "
            f"MCP only={sorted(set(names) - set(declared))}")
        assert set(names) == EXPECTED_TOOLS, f"Unexpected AI access scope: {names}"
        assert manifest["schemaVersion"] == 1 and manifest["transport"] == "mcp_stdio"
        assert manifest["arguments"] == ["--mcp"]
        assert re.fullmatch(r"[a-z0-9_]{1,16}", manifest["id"])
        for tool in tools:
            assert re.fullmatch(r"[a-z0-9_]{1,32}", tool["name"])
            assert tool["description"] and tool["inputSchema"]["additionalProperties"] is False
            assert set(tool["annotations"]) == {
                "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"}
        print("PASS bundled manifest equals all tools/list pages; exactly fourteen AI-scoped tools")

        def invalid(name, arguments):
            response = client.rpc("tools/call", {"name": name, "arguments": arguments})
            assert response.get("error", {}).get("code") == -32602, response

        for tool in tools:
            invalid(tool["name"], {"unexpected": True})
        for name in ("receive_exchange_text_file", "receive_text_file"):
            invalid(name, {"filename": "large.txt", "content": "x" * (128 * 1024 + 1)})
            invalid(name, {"filename": "", "content": "text"})
        invalid("list_shared_files", {"limit": True})
        invalid("read_shared_file", {"id": "../outside", "limit": 3})
        for name in {"send_text", "send_files", "add_inbox_files", "list_inbox", "list_outbox",
                     "get_status", "get_item", "list_events", "receive_files", "receive_all",
                     "cancel_inbox_files", "cancel_outbox_files", "list_history", "list_jobs", "missing"}:
            invalid(name, {})
        for cursor in ("-1", "not-a-cursor", str(len(names)), True):
            assert client.rpc("tools/list", {"cursor": cursor})["error"]["code"] == -32602
        assert client.rpc("missing")["error"]["code"] == -32601
        print("PASS argument validation, invalid cursors, removed tools and unknown methods")
        print("PASS protocol checks do not launch/stop the GUI or access user files")
        print(f"Maximum MCP request latency: {client.maximum_latency:.3f}s")
    finally:
        client.close()


if __name__ == "__main__":
    main()
