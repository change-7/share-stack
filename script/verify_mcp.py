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

    def wait(self, job, expected="succeeded"):
        for _ in range(150):
            self.called_tools.add("get_job")
            result = self.rpc("tools/call", {"name": "get_job", "arguments": {"id": job["id"]}})["result"]
            assert not result.get("isError"), result
            value = result["structuredContent"]
            assert "results" not in value
            if value["status"] in {"succeeded", "partial_failure", "failed", "cancelled", "interrupted"}:
                assert value["status"] in ({expected} if isinstance(expected, str) else expected), value
                return value
            time.sleep(0.05)
        raise AssertionError("Job did not finish")

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert not self.process.stdout.read(), "Unexpected stdout after EOF"
        self.selector.close()
        self.stderr.close()


def stop_gui(executable):
    try:
        listing = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    except PermissionError:
        print("SKIP GUI process control: sandbox denies ps")
        return False
    for line in listing.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[1] == str(executable):
            os.kill(int(fields[0]), signal.SIGTERM)
    time.sleep(0.5)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", default="ShareStackMac.app")
    args = parser.parse_args()
    bundle = Path(args.bundle).resolve()
    executable = bundle / "Contents/MacOS/ShareStackMac"
    can_control_gui = stop_gui(executable)
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
    assert len(names) == len(set(names)) == 18, f"unexpected tool list: {names}"
    assert {"list_shared_files", "get_shared_file_info", "read_shared_file"}.issubset(names)
    for tool in tools:
        assert re.fullmatch(r"[a-z0-9_]{1,32}", tool["name"])
        assert tool["description"] and tool["inputSchema"]["additionalProperties"] is False
        assert set(tool["annotations"]) == {"readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"}
    print("PASS initialize, initialized notification, tools/list pagination and annotations")
    status = client.tool("get_status")
    assert "inboxCount" in status
    if can_control_gui:
        print("PASS GUI-off cold start and authenticated, pinned live status")
    else:
        print("PASS authenticated, pinned live status")
    assert client.rpc("tools/call", {"name": "send_text", "arguments": {"text": ""}})["error"]["code"] == -32602
    assert client.rpc("tools/call", {"name": "receive_text_file", "arguments": {"filename": "large.srt", "content": "x" * (128 * 1024 + 1)}})["error"]["code"] == -32602
    assert client.rpc("tools/call", {"name": "list_inbox", "arguments": {"limit": True}})["error"]["code"] == -32602
    assert client.rpc("tools/call", {"name": "read_shared_file", "arguments": {"id": str(uuid.uuid4()), "limit": 3}})["error"]["code"] == -32602
    assert client.rpc("tools/call", {"name": "get_status", "arguments": {"unexpected": 1}})["error"]["code"] == -32602
    assert client.rpc("tools/call", {"name": "missing"})["error"]["code"] == -32602
    assert client.rpc("missing")["error"]["code"] == -32601
    print("PASS invalid input and unknown-method handling")
    original_inbox = client.tool("list_inbox")["items"]
    assert "list_history" not in names and "list_jobs" not in names
    client.tool("list_outbox")
    events = client.tool("list_events")
    client.tool("list_events", {"after": events["nextCursor"], "streamID": events["streamID"]})
    client.tool("get_item", {"id": str(uuid.uuid4())}, error=True)
    marker = "sharestack-mcp-verify-" + str(uuid.uuid4())
    cleanup_outbox = []
    saved_files = []
    direct_inbox_ids = []
    try:
        sent = client.tool("send_text", {"text": marker})
        client.wait(sent)
        outgoing = client.tool("list_outbox")["items"]
        import hashlib
        text_hash = hashlib.sha256(marker.encode()).hexdigest()
        cleanup_outbox.extend(item["id"] for item in outgoing if item["sha256"] == text_hash)
        assert len(cleanup_outbox) == 1
        assert client.tool("get_item", {"id": cleanup_outbox[0]})["state"] == "pending"
        with tempfile.TemporaryDirectory(prefix=marker) as directory:
            source = Path(directory) / (marker + ".txt")
            source.write_text(marker + "-file")
            client.wait(client.tool("send_files", {"paths": [str(source)]}))
            assert source.read_text() == marker + "-file"
            matches = [item for item in client.tool("list_outbox")["items"] if item["name"] == source.name]
            assert len(matches) == 1
            cleanup_outbox.extend(item["id"] for item in matches)
            before_failure = {item["id"] for item in client.tool("list_outbox")["items"]}
            failed = client.wait(client.tool("send_files", {"paths": [str(source) + ".missing"]}), expected="failed")
            assert failed["failures"]
            assert {item["id"] for item in client.tool("list_outbox")["items"]} == before_failure
        second = Client(executable)
        assert second.tool("get_job", {"id": sent["id"]})["status"] == "succeeded"
        second.close()
        print("PASS real text/file queue, original preservation, failure results and completed job retention")
        subtitle = f"1\n00:00:00,000 --> 00:00:01,000\n{marker} subtitle\n"
        second_subtitle = subtitle + "\n2\n00:00:01,000 --> 00:00:02,000\nsecond cue\n"
        filename = marker + ".srt"
        for payload in (subtitle, second_subtitle):
            job = client.tool("receive_text_file", {"filename": "../" + filename, "content": payload})
            client.wait(job)
        direct_items = [item for item in client.tool("list_inbox")["items"] if item["name"] == filename]
        if status["receiptSettings"]["mode"] == "automatic":
            direct_paths = [Path(status["receiptSettings"]["folderPath"]) / filename,
                            Path(status["receiptSettings"]["folderPath"]) / f"{marker} (1).srt"]
        else:
            assert len(direct_items) == 2, direct_items
            by_hash = {item["sha256"]: item for item in direct_items}
            direct_inbox_ids = [by_hash[hashlib.sha256(payload.encode()).hexdigest()]["id"]
                                for payload in (subtitle, second_subtitle)]
            assert set(by_hash) == {hashlib.sha256(payload.encode()).hexdigest()
                                    for payload in (subtitle, second_subtitle)}
            direct_paths = [Path(status["receiptSettings"]["folderPath"]) / filename,
                            Path(status["receiptSettings"]["folderPath"]) / f"{marker} (1).srt"]
            saved_files.extend((path, payload.encode()) for path, payload in zip(direct_paths, (subtitle, second_subtitle)))
            client.wait(client.tool("receive_files", {"ids": direct_inbox_ids}))
        for path, payload in zip(direct_paths, (subtitle, second_subtitle)):
            if status["receiptSettings"]["mode"] == "automatic":
                saved_files.append((path, payload.encode()))
            assert path.read_bytes() == payload.encode()
        assert not (Path(status["receiptSettings"]["folderPath"]) / "large.srt").exists()
        if direct_inbox_ids:
            saved_info = client.tool("get_shared_file_info", {"id": direct_inbox_ids[0]})
            saved_chunk = client.tool("read_shared_file", {"id": direct_inbox_ids[0]})
            assert saved_info["state"] == "saved" and saved_info["isReadable"]
            assert saved_chunk["content"] == subtitle and not saved_chunk["hasMore"]
        print("PASS direct MCP text-file payload, SHA-256 verified storage, traversal-safe names and collision renaming")

        long_text = "한日本語🙂\n" * 5500
        long_name = marker + ".md"
        client.wait(client.tool("receive_text_file", {"filename": long_name, "content": long_text}))
        shared_page = client.tool("list_shared_files", {"limit": 100})
        shared_match = next(item for item in shared_page["items"] if item["name"] == long_name)
        file_id = shared_match["id"]
        info = client.tool("get_shared_file_info", {"id": file_id})
        expected_bytes = long_text.encode("utf-8")
        assert info["isReadable"] and info["size"] == len(expected_bytes)
        assert info["sha256"] == hashlib.sha256(expected_bytes).hexdigest()
        pieces = []
        offset = 0
        while True:
            chunk = client.tool("read_shared_file", {"id": file_id, "offset": offset, "limit": 32768})
            pieces.append(chunk["content"])
            assert chunk["offset"] == offset and chunk["bytesRead"] == len(chunk["content"].encode("utf-8"))
            assert chunk["nextOffset"] == offset + chunk["bytesRead"]
            offset = chunk["nextOffset"]
            if not chunk["hasMore"]:
                break
        assert "".join(pieces) == long_text and offset == len(expected_bytes)
        print("PASS real list_shared_files/get_shared_file_info/read_shared_file MCP calls and UTF-8-safe chunk reconstruction")
        if status["receiptSettings"]["mode"] == "automatic":
            saved_path = Path(status["receiptSettings"]["folderPath"]) / long_name
            saved_files.append((saved_path, expected_bytes))
            saved_path.unlink()
            assert not client.tool("get_shared_file_info", {"id": file_id})["isReadable"]
        else:
            client.wait(client.tool("cancel_inbox_files", {"ids": [file_id]}))
        client.tool("read_shared_file", {"id": file_id}, error=True)
        print("PASS deleted or cancelled shared files are no longer readable")
        for number in range(3):
            with tempfile.TemporaryDirectory(prefix=marker) as directory:
                source = Path(directory) / f"{marker}-{number}.txt"
                source.write_text(marker + str(number))
                client.wait(client.tool("add_inbox_files", {"paths": [str(source)]}))
                assert source.read_text() == marker + str(number)
                matches = [item for item in client.tool("list_inbox")["items"] if item["name"] == source.name]
                saved_path = Path(status["receiptSettings"]["folderPath"]) / source.name
            if status["receiptSettings"]["mode"] == "automatic":
                assert not matches
                saved_files.append((saved_path, (marker + str(number)).encode()))
                continue
            assert len(matches) == 1
            item = matches[0]
            if number == 0:
                client.wait(client.tool("receive_files", {"ids": [item["id"]]}))
                saved_files.append((saved_path, (marker + str(number)).encode()))
            elif number == 1 and not original_inbox:
                client.wait(client.tool("receive_all"))
                saved_files.append((saved_path, (marker + str(number)).encode()))
            else:
                client.wait(client.tool("cancel_inbox_files", {"ids": [item["id"]]}))
                client.tool("get_item", {"id": item["id"]}, error=True)
        for path, payload in saved_files:
            assert path.read_bytes() == payload
        print("PASS real incoming fixture upload, receipt/move and temporary-file cancellation")
        if original_inbox:
            print("SKIP receive_all: existing user inbox files were preserved")
        queued = client.tool("receive_files", {"ids": [str(uuid.uuid4()) for _ in range(100)]})
        client.called_tools.add("cancel_job")
        cancellation = client.rpc("tools/call", {"name": "cancel_job", "arguments": {"id": queued["id"]}})["result"]
        assert not cancellation.get("isError"), cancellation
        client.wait(queued, expected={"cancelled", "failed", "partial_failure"})
        print("PASS job cancellation request and terminal status")
        events = client.tool("list_events")
        assert {"file.received", "file.saved", "file.cancelled"}.issubset({event["type"] for event in events["events"]})
        if can_control_gui:
            stop_gui(executable)
            client.tool("get_status")
            client.tool("get_job", {"id": sent["id"]}, error=True)
            print("PASS GUI restart, automatic reconnection and expiration of previous job results")
        else:
            print("SKIP GUI restart/expiration: sandbox denied process control")
        manifest = bundle / "Contents/Resources/linkdeck.json"
        if manifest.exists():
            value = json.loads(manifest.read_text(encoding="utf-8"))
            assert value["schemaVersion"] == 1 and value["transport"] == "mcp_stdio"
            assert value["arguments"] == ["--mcp"] and set(value["tools"]) == set(names)
            assert re.fullmatch(r"[a-z0-9_]{1,16}", value["id"])
            print("PASS bundled LinkDeck manifest matches all actual tools/list pages")
    finally:
        if direct_inbox_ids:
            remaining_ids = {item["id"] for item in client.tool("list_inbox")["items"]}
            remaining_direct = list(remaining_ids.intersection(direct_inbox_ids))
            if remaining_direct:
                client.wait(client.tool("cancel_inbox_files", {"ids": remaining_direct}))
        if cleanup_outbox:
            client.wait(client.tool("cancel_outbox_files", {"ids": list(dict.fromkeys(cleanup_outbox))}))
            remaining = {item["id"] for item in client.tool("list_outbox")["items"]}
            assert not remaining.intersection(cleanup_outbox)
        print("MCP tools exercised: " + ", ".join(sorted(client.called_tools)))
        skipped = {"receive_all"} if original_inbox else set()
        if status["receiptSettings"]["mode"] == "automatic":
            skipped.add("cancel_inbox_files")
        assert set(names) - client.called_tools <= skipped, set(names) - client.called_tools - skipped
        for path, payload in saved_files:
            if path.exists() and marker in path.name:
                path.unlink()
        print(f"Maximum MCP request latency: {client.maximum_latency:.3f}s")
        client.close()


if __name__ == "__main__":
    main()
