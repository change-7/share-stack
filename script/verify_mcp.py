import argparse
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import tempfile
import time
import uuid


class Client:
    def __init__(self, executable):
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen([str(executable), "--mcp"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.sequence = 0
        self.maximum_latency = 0
        self.called_tools = set()
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

    def tool(self, name, arguments=None, error=False):
        self.called_tools.add(name)
        response = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        assert "result" in response, response
        result = response["result"]
        assert bool(result.get("isError")) == error, result
        if error:
            return result
        parsed = json.loads(result["content"][0]["text"])
        assert parsed == result["structuredContent"]
        return parsed

    def wait(self, job):
        for _ in range(150):
            value = self.tool("get_job", {"id": job["id"]})
            if value["status"] in {"succeeded", "partial_failure", "failed", "cancelled", "interrupted"}:
                return value
            time.sleep(0.05)
        raise AssertionError("Job did not reach a terminal state")

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert not self.process.stdout.read(), "Unexpected stdout after EOF"
        self.selector.close()
        self.stderr.close()


def stop_gui(executable):
    listing = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    for line in listing.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[1] == str(executable):
            os.kill(int(fields[0]), signal.SIGTERM)
    time.sleep(0.5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", default="ShareStackMac.app")
    args = parser.parse_args()
    bundle = Path(args.bundle).resolve()
    executable = bundle / "Contents/MacOS/ShareStackMac"
    stop_gui(executable)
    client = Client(executable)
    tools = []
    params = {}
    while True:
        page = client.rpc("tools/list", params)["result"]
        tools.extend(page["tools"])
        if "nextCursor" not in page:
            break
        params = {"cursor": page["nextCursor"]}
    names = [tool["name"] for tool in tools]
    assert len(names) == len(set(names)) == 16
    for tool in tools:
        assert re.fullmatch(r"[a-z0-9_]{1,32}", tool["name"])
        assert tool["description"] and tool["inputSchema"]["additionalProperties"] is False
        assert set(tool["annotations"]) == {"readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"}
    print("PASS initialize, initialized notification, tools/list pagination and annotations")
    status = client.tool("get_status")
    assert "inboxCount" in status
    print("PASS GUI-off cold start and authenticated, pinned live status")
    assert client.rpc("tools/call", {"name": "send_text", "arguments": {"text": ""}})["error"]["code"] == -32602
    assert client.rpc("tools/call", {"name": "list_inbox", "arguments": {"limit": True}})["error"]["code"] == -32602
    assert client.rpc("tools/call", {"name": "get_status", "arguments": {"unexpected": 1}})["error"]["code"] == -32602
    assert client.rpc("tools/call", {"name": "missing"})["error"]["code"] == -32602
    assert client.rpc("missing")["error"]["code"] == -32601
    print("PASS invalid input and unknown-method handling")
    original_inbox = client.tool("list_inbox")["items"]
    client.tool("list_history")
    client.tool("list_outbox")
    events = client.tool("list_events")
    client.tool("list_events", {"after": events["nextCursor"], "streamID": events["streamID"]})
    client.tool("get_item", {"id": str(uuid.uuid4())}, error=True)
    marker = "sharestack-mcp-verify-" + str(uuid.uuid4())
    cleanup_outbox = []
    saved_files = []
    try:
        sent = client.wait(client.tool("send_text", {"text": marker}))
        assert sent["status"] == "succeeded" and len(sent["results"]) == 1
        cleanup_outbox.append(sent["results"][0]["id"])
        assert client.tool("get_item", {"id": cleanup_outbox[0]})["state"] == "pending"
        with tempfile.TemporaryDirectory(prefix=marker) as directory:
            source = Path(directory) / (marker + ".txt")
            source.write_text(marker + "-file")
            sent_file = client.wait(client.tool("send_files", {"paths": [str(source)]}))
            assert sent_file["status"] == "succeeded" and source.read_text() == marker + "-file"
            cleanup_outbox.extend(item["id"] for item in sent_file["results"])
            failure = client.wait(client.tool("send_files", {"paths": [str(source) + ".missing"]}))
            assert failure["status"] == "failed" and failure["failures"]
        second = Client(executable)
        assert second.tool("get_job", {"id": sent["id"]})["status"] == "succeeded"
        second.close()
        print("PASS real text/file queue, original preservation, failure results and MCP reconnect")
        for number in range(3):
            with tempfile.TemporaryDirectory(prefix=marker) as directory:
                source = Path(directory) / f"{marker}-{number}.txt"
                source.write_text(marker + str(number))
                imported = client.wait(client.tool("add_inbox_files", {"paths": [str(source)]}))
                assert imported["status"] == "succeeded" and source.read_text() == marker + str(number)
                item = imported["results"][0]
            if item["state"] == "saved":
                saved_files.append((Path(item["savedPath"]), (marker + str(number)).encode()))
                continue
            if number == 0:
                received = client.wait(client.tool("receive_files", {"ids": [item["id"]]}))
                assert received["status"] == "succeeded"
                result = received["results"][0]
                saved_files.append((Path(result["savedPath"]), (marker + str(number)).encode()))
            elif number == 1 and not original_inbox:
                received = client.wait(client.tool("receive_all"))
                assert received["status"] == "succeeded"
                result = next(value for value in received["results"] if value["id"] == item["id"])
                saved_files.append((Path(result["savedPath"]), (marker + str(number)).encode()))
            else:
                cancelled = client.wait(client.tool("cancel_inbox_files", {"ids": [item["id"]]}))
                assert cancelled["status"] == "succeeded"
                client.tool("get_item", {"id": item["id"]}, error=True)
        for path, payload in saved_files:
            assert path.read_bytes() == payload
        print("PASS real incoming fixture upload, receipt/move and temporary-file cancellation")
        if original_inbox:
            print("SKIP receive_all: existing user inbox files were preserved")
        queued = client.tool("receive_files", {"ids": [str(uuid.uuid4()) for _ in range(100)]})
        cancelled = client.tool("cancel_job", {"id": queued["id"]})
        terminal = client.wait(cancelled)
        assert terminal["status"] in {"cancelled", "failed"}
        print("PASS job cancellation request and terminal status")
        assert client.tool("list_jobs")["items"]
        events = client.tool("list_events")
        assert {"file.received", "file.saved", "file.cancelled"}.issubset({event["type"] for event in events["events"]})
        stop_gui(executable)
        client.tool("get_status")
        assert client.tool("get_job", {"id": sent["id"]})["status"] == "succeeded"
        print("PASS GUI restart, automatic reconnection and persisted job results")
        active = client.tool("receive_files", {"ids": [str(uuid.uuid4()) for _ in range(100)]})
        stop_gui(executable)
        persisted = json.loads((Path.home() / "Library/Application Support/ShareStackMac/jobs" / (active["id"] + ".json")).read_text())
        client.tool("get_status")
        recovered = client.tool("get_job", {"id": active["id"]})
        expected = persisted["status"] if persisted["status"] in {"succeeded", "partial_failure", "failed", "cancelled"} else "interrupted"
        assert recovered["status"] == expected
        print("PASS interrupted job recovery from persisted GUI state")
        manifest = bundle / "Contents/Resources/linkdeck.json"
        if manifest.exists():
            value = json.loads(manifest.read_text(encoding="utf-8"))
            assert value["schemaVersion"] == 1 and value["transport"] == "mcp_stdio"
            assert value["arguments"] == ["--mcp"] and set(value["tools"]) == set(names)
            assert re.fullmatch(r"[a-z0-9_]{1,16}", value["id"])
            print("PASS bundled LinkDeck manifest matches all actual tools/list pages")
    finally:
        if cleanup_outbox:
            removed = client.wait(client.tool("cancel_outbox_files", {"ids": list(dict.fromkeys(cleanup_outbox))}))
            assert removed["status"] == "succeeded", removed
        print("MCP tools exercised: " + ", ".join(sorted(client.called_tools)))
        assert set(names) - client.called_tools <= ({"receive_all"} if original_inbox else set())
        for path, payload in saved_files:
            if path.exists() and path.read_bytes() == payload and marker in path.name:
                path.unlink()
        print(f"Maximum MCP request latency: {client.maximum_latency:.3f}s")
        client.close()


if __name__ == "__main__":
    main()
