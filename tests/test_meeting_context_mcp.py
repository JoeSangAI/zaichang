"""Transport contract checks; synthetic transcripts only, no capture or cloud."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock
from tests import test_meeting_context as fixture_module

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "agent-plugin/zaichang/scripts/mcp_server.py"
spec = importlib.util.spec_from_file_location("zaichang_mcp", SERVER)
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


class MeetingMCPTests(unittest.TestCase):
    def request(self, method, params=None):
        return mcp.handle({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})

    def test_tool_discovery_and_read_only_scope(self):
        tools = self.request("tools/list")["result"]["tools"]
        self.assertEqual({t["name"] for t in tools},
                         {"current_meeting", "read_meeting", "search_meeting", "meeting_changes"})
        for tool in tools:
            self.assertTrue(tool["annotations"]["readOnlyHint"])
            self.assertFalse(tool["annotations"]["openWorldHint"])
            self.assertFalse(tool["inputSchema"]["additionalProperties"])

    def test_initialization_and_notification(self):
        value = self.request("initialize", {"protocolVersion": "2025-03-26"})["result"]
        self.assertEqual(value["protocolVersion"], "2025-03-26")
        self.assertEqual(value["serverInfo"]["version"], "0.2.3")
        self.assertIsNone(mcp.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))

    def test_invalid_arguments_cannot_select_files_or_commands(self):
        for name, args in [("stop", {}), ("current_meeting", {"database": "/private/x"}),
                           ("read_meeting", {"session": "../../x"}),
                           ("read_meeting", {"session": "s", "limit": True}),
                           ("read_meeting", {"session": "s", "limit": 121}),
                           ("meeting_changes", {"session": "s"}),
                           ("search_meeting", {"session": "s", "query": ""})]:
            self.assertEqual(self.request("tools/call", {"name": name, "arguments": args})["error"]["code"], -32602)
        self.assertEqual(mcp.arguments("current_meeting", {"query": "--database=/x"}),
                         ["current", "--query=--database=/x"])

    def test_failure_and_timeout_do_not_claim_idle(self):
        for failure in [subprocess.TimeoutExpired("reader", 4), OSError("unavailable")]:
            with mock.patch.object(mcp.subprocess, "run", side_effect=failure):
                result = mcp.call_tool("current_meeting", {})
                self.assertTrue(result["isError"])
                self.assertEqual(result["structuredContent"]["status"], "error")

    def test_real_stdio_transport(self):
        messages = ["not json", json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                           "params": {"protocolVersion": "2025-11-25"}}),
                    json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
                    json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
                    json.dumps({"jsonrpc": "2.0", "id": 3, "method": "ping"})]
        result = subprocess.run([sys.executable, str(SERVER)], input="\n".join(messages)+"\n",
                                text=True, capture_output=True, timeout=5, check=True)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]["error"]["code"], -32700)
        self.assertEqual(len(rows[2]["result"]["tools"]), 4)
        self.assertEqual(result.stderr, "")

    def test_reader_end_to_end_states_and_all_tools(self):
        fixture = fixture_module.MeetingContextTests()
        fixture.setUp()
        try:
            # A private test launcher pins only this synthetic database. The
            # shipped launcher cannot accept a database from MCP arguments.
            wrapper = Path(fixture.temp.name) / "reader.sh"
            import shlex
            wrapper.write_text("#!/bin/sh\nexec " + " ".join(map(shlex.quote,
                [sys.executable, str(ROOT / "meeting_context.py"), "--database", str(fixture.db)])) + ' "$@"\n')
            with mock.patch.object(mcp, "READER", wrapper):
                idle = mcp.call_tool("current_meeting", {})["structuredContent"]
                self.assertEqual(idle["status"], "no_current_meeting")
                fixture.meeting("s-live", revision=3)
                fixture.state()
                fixture.segment("s-live", "one", start=1, updated_revision=3,
                                payload=[fixture_module.turn("合成测试：讨论财报", speaker="测试人物", start=1)])
                for name, args in [("current_meeting", {}), ("read_meeting", {"session": "s-live"}),
                                   ("search_meeting", {"session": "s-live", "query": "财报"}),
                                   ("meeting_changes", {"session": "s-live", "after_revision": 1})]:
                    response = mcp.call_tool(name, args)
                    self.assertFalse(response["isError"], response)
                    self.assertIn("合成测试", json.dumps(response, ensure_ascii=False))
                    self.assertNotIn("/private/audio.wav", json.dumps(response))
                    self.assertNotIn("embedding", json.dumps(response))
                fixture.meeting("s-live", local_only=True)
                self.assertTrue(mcp.call_tool("current_meeting", {})["structuredContent"]["meeting"]["local_only"])
                fixture.state(heartbeat=time.time()-60)
                stale = mcp.call_tool("current_meeting", {})["structuredContent"]
                self.assertEqual(stale["reason"], "writer_unreachable_or_stale")
        finally:
            fixture.tearDown()


if __name__ == "__main__":
    unittest.main()
