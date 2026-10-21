import asyncio
import json
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock

from codex_runtime import CodexRuntime, RuntimeErrorCode


class CodexTransportTests(unittest.IsolatedAsyncioTestCase):
    """Protocol failure injection; live subscription evidence is a separate probe."""

    async def test_lost_start_reply_blocks_replay_without_blocking_other_thread(self):
        runtime = CodexRuntime()
        runtime._send = AsyncMock()
        with self.assertRaisesRegex(RuntimeErrorCode, "rpc_outcome_unknown"):
            await runtime.request("turn/start", {"threadId": "foreground"}, timeout=.01)
        with self.assertRaisesRegex(RuntimeErrorCode, "turn_start_requires_reconciliation"):
            await runtime.start_turn("foreground", "do not duplicate")
        self.assertNotIn("background", runtime.uncertain_starts)
        self.assertEqual(runtime._send.await_count, 1)
        self.assertEqual(runtime._pending, {})

    async def test_local_cancel_is_unknown_remote_outcome_not_claimed_interruption(self):
        runtime = CodexRuntime()
        runtime._send = AsyncMock()
        task = asyncio.create_task(runtime.start_turn("foreground", "task"))
        await asyncio.sleep(0)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertIn("foreground", runtime.uncertain_starts)
        self.assertEqual(runtime._pending, {})

    async def test_interleaved_events_remain_in_their_threads_and_disconnect_wakes_waiters(self):
        runtime = CodexRuntime()
        stdout = asyncio.StreamReader()
        runtime.process = SimpleNamespace(stdout=stdout)
        runtime.closed = False
        reader = asyncio.create_task(runtime._read())
        for thread in ["background", "foreground", "background"]:
            stdout.feed_data(json.dumps({"method": "turn/completed", "params": {"threadId": thread}}).encode() + b"\n")
        self.assertEqual((await runtime.event("foreground"))["params"]["threadId"], "foreground")
        self.assertEqual((await runtime.event("background"))["params"]["threadId"], "background")
        self.assertEqual((await runtime.event("background"))["params"]["threadId"], "background")
        waiter = asyncio.create_task(runtime.event("foreground"))
        stdout.feed_eof()
        await reader
        with self.assertRaisesRegex(RuntimeErrorCode, "runtime_disconnected"):
            await waiter

    async def test_threadless_notifications_are_discarded_without_closing_runtime(self):
        runtime = CodexRuntime()
        stdout = asyncio.StreamReader()
        runtime.process = SimpleNamespace(stdout=stdout)
        runtime.closed = False
        reader = asyncio.create_task(runtime._read())
        for index in range(2050):
            stdout.feed_data(json.dumps({"method": "server/status", "params": {"index": index}}).encode() + b"\n")
        stdout.feed_data(json.dumps({"method": "turn/completed", "params": {"threadId": "active"}}).encode() + b"\n")
        await asyncio.sleep(0.02)
        self.assertFalse(reader.done())
        self.assertFalse(runtime.closed)
        self.assertEqual((await runtime.event("active"))["params"]["threadId"], "active")
        stdout.feed_eof()
        await reader

    async def test_event_overflow_is_limited_to_one_thread(self):
        runtime = CodexRuntime()
        stdout = asyncio.StreamReader()
        runtime.process = SimpleNamespace(stdout=stdout)
        runtime.closed = False
        reader = asyncio.create_task(runtime._read())
        for index in range(2049):
            stdout.feed_data(json.dumps({"method": "item/completed", "params": {
                "threadId": "slow", "index": index}}).encode() + b"\n")
        stdout.feed_data(json.dumps({"method": "turn/completed", "params": {"threadId": "healthy"}}).encode() + b"\n")
        await asyncio.sleep(0.03)
        self.assertFalse(reader.done())
        self.assertFalse(runtime.closed)
        self.assertEqual((await runtime.event("healthy"))["params"]["threadId"], "healthy")
        with self.assertRaisesRegex(RuntimeErrorCode, "event_consumer_overflow"):
            await runtime.event("slow")
        stdout.feed_eof()
        await reader

    async def test_missing_approval_ui_never_grants_server_request(self):
        runtime = CodexRuntime()
        runtime._send = AsyncMock()
        await runtime._answer({"id": 23, "method": "item/commandExecution/requestApproval", "params": {"threadId": "background"}})
        response = runtime._send.call_args.args[0]
        self.assertEqual(response["id"], 23)
        self.assertIn("error", response)
        self.assertNotIn("result", response)

    async def test_server_request_id_is_forwarded_to_task_scoped_approval_router(self):
        handler = AsyncMock(return_value={"decision": "decline"})
        runtime = CodexRuntime(on_request=handler)
        runtime._send = AsyncMock()
        await runtime._answer({"id": "req-7", "method": "item/fileChange/requestApproval",
                               "params": {"threadId": "worker-1"}})
        self.assertEqual(handler.await_args.args[0], "item/fileChange/requestApproval")
        self.assertEqual(handler.await_args.args[1], {"threadId": "worker-1", "_serverRequestId": "req-7"})
        self.assertEqual(runtime._send.await_args.args[0], {"id": "req-7", "result": {"decision": "decline"}})

    async def test_thread_start_passes_role_permissions_and_experimental_dynamic_tools(self):
        runtime = CodexRuntime()
        runtime.request = AsyncMock(return_value={"thread": {"id": "t"}})
        tools = [{"type": "function", "name": "assistant_job_list", "description": "list", "inputSchema": {"type": "object"}}]
        await runtime.start_thread("/project", sandbox="workspace-write", approval_policy="on-request",
                                   dynamic_tools=tools, developer_instructions="task scope")
        method, params = runtime.request.await_args.args[:2]
        self.assertEqual(method, "thread/start")
        self.assertEqual(params["sandbox"], "workspace-write")
        self.assertEqual(params["approvalPolicy"], "on-request")
        self.assertEqual(params["dynamicTools"], tools)
        self.assertEqual(params["developerInstructions"], "task scope")

    async def test_dynamic_tools_are_refused_when_experimental_api_is_disabled(self):
        runtime = CodexRuntime(experimental_api=False)
        runtime.request = AsyncMock()
        with self.assertRaisesRegex(RuntimeErrorCode, "dynamic_tools_require_experimental_api"):
            await runtime.start_thread("/project", dynamic_tools=[{"name": "task"}])
        runtime.request.assert_not_awaited()
