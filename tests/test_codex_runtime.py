import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from unittest.mock import AsyncMock

from codex_runtime import CodexPool, CodexRuntime, NO_TOOLS_ARGS, RuntimeErrorCode, process_headroom


class CodexTransportTests(unittest.IsolatedAsyncioTestCase):
    """Protocol failure injection; live subscription evidence is a separate probe."""

    async def test_user_execution_and_listener_reset_permissions_every_turn(self):
        runtime=CodexRuntime();runtime.request=AsyncMock(return_value={'turn':{'id':'t'}})
        await runtime.start_turn('thread','我主动交办时要能完整执行',execution_directory='/tmp/zaichang-output',full_access=True)
        execution=runtime.request.await_args.args[1]
        self.assertEqual(execution['approvalPolicy'],'never')
        self.assertEqual(execution['sandboxPolicy']['type'],'dangerFullAccess')
        self.assertEqual(execution['cwd'],'/tmp/zaichang-output')
        await runtime.start_turn('thread','旁听自己发起的任务只写作品目录',execution_directory='/tmp/zaichang-output')
        proactive=runtime.request.await_args.args[1]
        self.assertEqual(proactive['approvalPolicy'],'never')
        self.assertEqual(proactive['sandboxPolicy'],{'type':'workspaceWrite','writableRoots':['/tmp/zaichang-output'],'networkAccess':True})
        await runtime.start_turn('thread','旁听保持只读')
        listener=runtime.request.await_args.args[1]
        self.assertEqual(listener['approvalPolicy'],'never')
        self.assertEqual(listener['sandboxPolicy']['type'],'readOnly')
        self.assertNotIn('model',listener)

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
        tools = [{"type": "function", "name": "meeting_read", "description": "list", "inputSchema": {"type": "object"}}]
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


class PoolMember:
    account = {"account": {"type": "chatgpt"}, "requiresOpenaiAuth": True}

    def __init__(self, *, on_request=None, args=()):
        self.args, self.closed, self.starts = args, False, 0
        PoolMember.made.append(self)

    async def start(self):
        self.starts += 1

    async def request(self, method, params=None, **kwargs):
        return PoolMember.account

    async def start_thread(self, cwd, **options):
        return {"thread": {"id": f"thread-{len(PoolMember.made)}"}, "options": options}

    async def close(self):
        self.closed = True


class CodexPoolTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        PoolMember.made = []
        self.pool = CodexPool(PoolMember, capacity=3)
        await self.pool.start()
        self.assertTrue(PoolMember.made.pop().closed)  # The startup probe holds nothing.

    async def test_each_thread_owns_a_process_and_release_ends_it(self):
        a = (await self.pool.start_thread("/tmp"))["thread"]["id"]
        b = (await self.pool.start_thread("/tmp"))["thread"]["id"]
        self.assertNotEqual(self.pool.members[a], self.pool.members[b])
        await self.pool.release(a); await self.pool.release(a)
        self.assertEqual(self.pool.threads(), {b})
        self.assertTrue(PoolMember.made[0].closed)
        self.assertFalse(PoolMember.made[1].closed)

    async def test_no_tools_process_carries_none_of_the_users_tools(self):
        await self.pool.start_thread("/tmp", tools=False)
        await self.pool.start_thread("/tmp")
        self.assertEqual(PoolMember.made[0].args, NO_TOOLS_ARGS)
        self.assertIn("mcp_servers={}", NO_TOOLS_ARGS)
        self.assertEqual(PoolMember.made[1].args, ())

    async def test_logged_out_codex_is_named_and_leaves_no_process(self):
        pool = CodexPool(PoolMember, capacity=3)
        made = len(PoolMember.made)
        with unittest.mock.patch.object(PoolMember, "account", {"account": None, "requiresOpenaiAuth": True}):
            with self.assertRaisesRegex(RuntimeErrorCode, "auth_required"):
                await pool.start()
        self.assertTrue(pool.closed)
        self.assertTrue(all(member.closed for member in PoolMember.made[made:]))

    async def test_missing_executable_is_named(self):
        with self.assertRaisesRegex(RuntimeErrorCode, "codex_not_installed"):
            await CodexRuntime("/nonexistent/codex").start()

    async def test_capacity_is_a_hard_limit(self):
        for _ in range(3):
            await self.pool.start_thread("/tmp")
        with self.assertRaisesRegex(RuntimeErrorCode, "runtime_capacity"):
            await self.pool.start_thread("/tmp")
        self.assertEqual(len(PoolMember.made), 3)

    async def test_spare_is_used_once_only_for_identical_options(self):
        await self.pool.warm("/tmp", model="a")
        await self.pool.warm("/tmp", model="a")
        self.assertEqual(len(PoolMember.made), 1)
        spare = PoolMember.made[0]
        other = (await self.pool.start_thread("/tmp", model="b"))["thread"]["id"]
        self.assertIsNot(self.pool.members[other], spare)
        same = (await self.pool.start_thread("/tmp", model="a"))["thread"]["id"]
        self.assertIs(self.pool.members[same], spare)
        self.assertIsNone(self.pool.spare)

    async def test_spare_gives_way_at_capacity(self):
        await self.pool.warm("/tmp", model="a")
        spare = PoolMember.made[0]
        for _ in range(3):
            await self.pool.start_thread("/tmp", model="b")
        self.assertTrue(spare.closed)
        self.assertIsNone(self.pool.spare)

    async def test_failed_start_closes_the_process(self):
        class Broken(PoolMember):
            async def start_thread(self, cwd, **options):
                raise RuntimeErrorCode("boom")
        self.pool.factory = Broken
        with self.assertRaisesRegex(RuntimeErrorCode, "boom"):
            await self.pool.start_thread("/tmp")
        self.assertTrue(PoolMember.made[-1].closed)
        self.assertFalse(self.pool.threads())

    async def test_close_ends_everything(self):
        await self.pool.start_thread("/tmp")
        await self.pool.warm("/tmp", model="a")
        await self.pool.close()
        self.assertTrue(all(member.closed for member in PoolMember.made))
        with self.assertRaisesRegex(RuntimeErrorCode, "runtime_closed"):
            await self.pool.start_thread("/tmp")

    async def test_unknown_thread_is_reported_as_missing(self):
        with self.assertRaisesRegex(RuntimeErrorCode, "thread_not_found"):
            await self.pool.event("gone", timeout=0)


class ProcessGroupTests(unittest.IsolatedAsyncioTestCase):
    async def test_close_takes_children_that_ignore_stdin_with_it(self):
        with tempfile.TemporaryDirectory() as root:
            script = Path(root) / "fake-codex"
            pidfile = Path(root) / "child.pid"
            script.write_text(f"""#!/bin/sh
sleep 300 &
echo $! > {pidfile}
while read line; do
  case "$line" in *'"initialize"'*) echo '{{"id":1,"result":{{}}}}';; esac
done
""")
            script.chmod(0o755)
            runtime = CodexRuntime(str(script))
            await runtime.start()
            child = int(pidfile.read_text())
            os.kill(child, 0)
            await runtime.close()
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)

    def test_spawn_refused_by_the_machine_has_a_name(self):
        async def run():
            with mock.patch("asyncio.create_subprocess_exec", side_effect=BlockingIOError(35, "again")):
                await CodexRuntime().start()
        with self.assertRaisesRegex(RuntimeErrorCode, "machine_process_limit"):
            asyncio.run(run())

    def test_headroom_is_zero_when_nothing_can_fork(self):
        with mock.patch("subprocess.run", side_effect=BlockingIOError(35, "again")):
            self.assertEqual(process_headroom(), 0)
