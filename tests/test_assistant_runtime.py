import asyncio
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

import assistant_runtime
from assistant_runtime import AssistantRuntime, AssistantStore, OVERVIEW_SCHEMA, SCOUT_SCHEMA
from codex_runtime import RuntimeErrorCode


class FakeAppServer:
    """In-process protocol adapter: deterministic events, no network/model calls."""

    def __init__(self, *, auto_complete=True, on_request=None):
        self.auto_complete = auto_complete
        self.on_request = on_request
        self.started = False
        self.start_count = 0
        self.closed = False
        self.strict_resume = False
        self.counter = 0
        self.threads = {}
        self.resumed_threads = set()
        self.events = {}
        self.requests = []
        self.thread_options = []

    async def start(self):
        self.started = True
        self.start_count += 1
        return {"userAgent": "fake"}

    async def start_thread(self, cwd, **options):
        self.counter += 1
        thread_id = f"thread-{self.counter}"
        self.threads[thread_id] = options
        self.thread_options.append(options)
        self.events.setdefault(thread_id, asyncio.Queue())
        return {"thread": {"id": thread_id}}

    async def resume_thread(self, thread_id, cwd, **options):
        self.resumed_threads.add(thread_id)
        self.events.setdefault(thread_id, asyncio.Queue())
        return {"thread": {"id": thread_id}}

    async def read_thread(self, thread_id):
        return {"thread": {"id": thread_id, "turns": []}}

    async def request(self, method, params=None, **kwargs):
        params = params or {}
        self.requests.append((method, params))
        if method == "turn/start":
            thread_id = params["threadId"]
            if self.strict_resume and thread_id not in self.threads and thread_id not in self.resumed_threads:
                raise RuntimeErrorCode("thread_not_resumed")
            self.counter += 1
            turn_id = f"turn-{self.counter}"
            if self.auto_complete:
                await self._complete(thread_id, turn_id, params)
            return {"turn": {"id": turn_id}}
        return {}

    async def start_turn(self, thread_id, text, *, output_schema=None):
        params = {"threadId": thread_id, "input": [{"type": "text", "text": text}]}
        if output_schema:
            params["outputSchema"] = output_schema
        return await self.request("turn/start", params)

    async def _complete(self, thread_id, turn_id, params):
        q = self.events.setdefault(thread_id, asyncio.Queue())
        await asyncio.sleep(0)
        if params.get("outputSchema"):
            if params["outputSchema"] == OVERVIEW_SCHEMA:
                text = json.dumps({"current_topic": {"text": "示例产品校园推广", "evidence": [
                    {"segment_id": "public-example-product-1", "quote": "示例产品是否做过校园推广"}]},
                    "discussion_points": [{"text": "团队尚不确定 Example Product 是否做过校园推广", "evidence": [
                        {"segment_id": "public-example-product-1", "quote": "团队不确定示例产品是否做过校园推广"}]}],
                    "decisions": [], "actions": [], "open_questions": [{"text": "Example Product 是否做过校园推广？", "evidence": [
                        {"segment_id": "public-example-product-1", "quote": "示例产品是否做过校园推广"}]}]}, ensure_ascii=False)
            else:
                text = json.dumps({"proposals": []}, ensure_ascii=False)
        else:
            text = "已完成"
        await q.put({"method": "item/completed", "params": {"threadId": thread_id,
            "item": {"id": f"item-{turn_id}", "type": "agentMessage",
                     "content": [{"type": "text", "text": text}]}}})
        await q.put({"method": "turn/completed", "params": {"threadId": thread_id,
            "turn": {"id": turn_id, "status": "completed"}}})

    async def event(self, thread_id, **kwargs):
        queue = self.events.setdefault(thread_id, asyncio.Queue())
        while not self.closed:
            try:
                return await asyncio.wait_for(queue.get(), .01)
            except asyncio.TimeoutError:
                continue
        raise RuntimeErrorCode("runtime_disconnected")

    async def interrupt(self, thread_id, turn_id):
        await self.events.setdefault(thread_id, asyncio.Queue()).put({"method": "turn/completed",
            "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted"}}})
        return {}

    async def close(self):
        self.closed = True


class AssistantRuntimeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store = AssistantStore(self.root / "store")
        self.fake = FakeAppServer()
        self.emitted = []

        async def emit(value):
            self.emitted.append(value)

        self.service = AssistantRuntime(self.store, self.root, runtime_factory=lambda **kw: self.fake, emit=emit)
        result = await self.service.bind("workspace-proposed", {"session_id": "session-1", "cache_id": "cache-1", "title": "广告策略会"})
        self.workspace_id = result["workspace_id"]

    async def test_quiet_native_tool_timeout_keeps_task_and_slot_until_completion(self):
        original = self.fake.event
        waits = 0
        async def event(thread_id, **kwargs):
            nonlocal waits
            waits += 1
            if waits == 1:
                raise asyncio.TimeoutError()
            return await original(thread_id, **kwargs)
        self.fake.event = event
        result = await self.service.cmd_send(self.workspace_id, {"text": "读取项目说明"})
        await self.wait_until(lambda: self.store.task(result["task_id"])["status"] == "completed")
        self.assertGreaterEqual(waits, 3)
        self.assertEqual(sum(method == "turn/start" for method, _ in self.fake.requests), 1)

    async def asyncTearDown(self):
        if not self.service._closed:
            await self.service.shutdown()
        self.store.close()
        self.tmp.cleanup()

    async def wait_until(self, predicate, timeout=1.0):
        end = asyncio.get_running_loop().time() + timeout
        while not predicate():
            if asyncio.get_running_loop().time() >= end:
                self.fail("condition not reached")
            await asyncio.sleep(0.005)

    async def test_binding_is_stable_and_conflicting_session_is_rejected(self):
        same = await self.service.bind("new-proposed-id", {"cache_id": "cache-1", "session_id": "session-1"})
        self.assertEqual(same["workspace_id"], self.workspace_id)
        with self.assertRaisesRegex(ValueError, "session_binding_conflict"):
            await self.service.bind("different", {"cache_id": "cache-1", "session_id": "other-session"})
        listed = await self.service.list_workspaces()
        self.assertEqual(listed["workspaces"][0]["id"], self.workspace_id)

    async def test_overview_migration_preserves_existing_task_and_message_rows(self):
        legacy_dir = self.root / "legacy-store"
        legacy_dir.mkdir()
        path = legacy_dir / "assistant.sqlite3"
        db = sqlite3.connect(path)
        db.executescript("""
            PRAGMA foreign_keys=ON;
            CREATE TABLE workspace (id TEXT PRIMARY KEY, cache_id TEXT, session_id TEXT, title TEXT NOT NULL DEFAULT '',
                context_database TEXT, proactive INTEGER NOT NULL DEFAULT 0, active_task_id TEXT,
                context_revision TEXT, context_hash TEXT, context_segment_ids TEXT NOT NULL DEFAULT '[]', updated REAL NOT NULL);
            CREATE UNIQUE INDEX workspace_cache_id ON workspace(cache_id) WHERE cache_id IS NOT NULL;
            CREATE UNIQUE INDEX workspace_session_id ON workspace(session_id) WHERE session_id IS NOT NULL;
            CREATE TABLE task (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL REFERENCES workspace(id),
                title TEXT NOT NULL, origin TEXT NOT NULL CHECK(origin IN ('user','proactive','scout')), status TEXT NOT NULL,
                thread_id TEXT, turn_id TEXT, goal TEXT NOT NULL DEFAULT '', goal_key TEXT NOT NULL DEFAULT '',
                source_refs TEXT NOT NULL DEFAULT '[]', lane TEXT NOT NULL DEFAULT 'background', parent_task_id TEXT,
                depth INTEGER NOT NULL DEFAULT 0, error TEXT, created REAL NOT NULL, updated REAL NOT NULL);
            CREATE INDEX task_workspace_status ON task(workspace_id,status,created);
            CREATE TABLE message (id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES task(id), role TEXT NOT NULL,
                text TEXT NOT NULL, status TEXT NOT NULL, origin TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL);
            CREATE INDEX message_task_created ON message(task_id,created);
            CREATE TABLE meeting_overview (workspace_id TEXT PRIMARY KEY REFERENCES workspace(id), status TEXT NOT NULL,
                data_json TEXT NOT NULL, source_hash TEXT NOT NULL DEFAULT '', error TEXT, updated REAL NOT NULL);
            INSERT INTO workspace(id,title,updated) VALUES('w1','Existing work',1);
            INSERT INTO task(id,workspace_id,title,origin,status,created,updated) VALUES('t1','w1','Existing task','user','completed',2,2);
            INSERT INTO message(id,task_id,role,text,status,origin,created,updated) VALUES('m1','t1','user','keep me','completed','user',3,3);
            INSERT INTO meeting_overview(workspace_id,status,data_json,source_hash,updated)
                VALUES('w1','ready','{"current_topic":{"text":"旧议题","evidence":[]},"discussion_points":[],"decisions":[],"actions":[],"open_questions":[]}','legacy-source-a',4);
        """)
        db.close()
        migrated = AssistantStore(legacy_dir)
        try:
            task = migrated.task("t1")
            self.assertEqual(task["kind"], "chat")
            self.assertEqual(task["title"], "Existing task")
            self.assertEqual(migrated.messages("w1")[0]["text"], "keep me")
            self.assertIsNotNone(migrated.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='meeting_overview'").fetchone())
            overview = migrated.db.execute("SELECT data_source_hash FROM meeting_overview WHERE workspace_id='w1'").fetchone()
            self.assertEqual(overview["data_source_hash"], "legacy-source-a")
        finally:
            migrated.close()

    async def test_concurrent_bind_waits_for_single_runtime_warm_handshake(self):
        gate = asyncio.Event()
        entered = asyncio.Event()

        class SlowStart(FakeAppServer):
            async def start(self):
                self.start_count += 1
                entered.set()
                await gate.wait()
                self.started = True
                return {"userAgent": "fake"}

            async def resume_thread(self, thread_id, cwd, **options):
                if not self.started:
                    raise AssertionError("resume_started_before_handshake")
                return await super().resume_thread(thread_id, cwd, **options)

        store = AssistantStore(self.root / "race-store")
        runtime = SlowStart()
        service = AssistantRuntime(store, self.root, runtime_factory=lambda **kw: runtime)
        first = asyncio.create_task(service.bind("race-workspace", {"cache_id": "race-cache", "session_id": "race-session"}))
        await entered.wait()
        second = asyncio.create_task(service.bind("ignored", {"cache_id": "race-cache", "session_id": "race-session"}))
        await asyncio.sleep(.02)
        self.assertFalse(second.done())
        self.assertEqual(runtime.start_count, 1)
        gate.set()
        first_result, second_result = await asyncio.gather(first, second)
        self.assertEqual(first_result["workspace_id"], second_result["workspace_id"])
        self.assertEqual(runtime.start_count, 1)
        await service.shutdown()
        store.close()

    async def test_context_is_memory_only_and_send_uses_a_codex_thread(self):
        private = "TRANSCRIPT_SHOULD_NOT_BE_PERSISTED_841"
        await self.service.cmd_context(self.workspace_id, {"title": "广告策略会", "session_id": "session-1",
            "segments": [{"id": "s1", "revision": 1, "text": private, "speaker": "A", "final": True},
                         {"id": "s2", "text": "unstable", "final": False}], "notes": "使用既有档案"})
        result = await self.service.cmd_send(self.workspace_id, {"text": "帮我查一下这个项目历史"})
        await self.wait_until(lambda: self.store.task(result["task_id"])["status"] == "completed")
        self.assertEqual(self.fake.thread_options[0]["sandbox"], "workspace-write")
        self.assertEqual(self.fake.thread_options[0]["approval_policy"], "on-request")
        prompt = [p for m, p in self.fake.requests if m == "turn/start"][0]["input"][0]["text"]
        self.assertIn(private, prompt)
        self.assertIn("untrusted data", prompt)
        self.assertIn("session_id=session-1", prompt)
        self.assertIn("cache_id=cache-1", prompt)
        self.assertIn("projection_hash=", prompt)
        self.assertNotIn(private.encode(), (self.root / "store" / "assistant.sqlite3").read_bytes())
        self.assertEqual(json.loads(self.store.workspace(self.workspace_id)["context_segment_ids"]), ["s1"])

    async def test_meeting_overview_uses_codex_schema_without_changing_chat_focus(self):
        speech = "团队不确定示例产品是否做过校园推广"
        await self.service.cmd_context(self.workspace_id, {"title": "示例产品校园推广", "notes": "PRIVATE_NOTE_SHOULD_NOT_ENTER_OVERVIEW",
            "segments": [{"id": "public-example-product-1", "revision": 1, "text": speech, "speaker": "说话人乙", "final": True},
                         {"id": "partial", "text": "unfinished", "final": False}]})
        result = await self.service.cmd_overview(self.workspace_id, {"active": True})
        self.assertTrue(result["queued"])
        await self.wait_until(lambda: self.store.db.execute("SELECT status FROM meeting_overview WHERE workspace_id=?",
            (self.workspace_id,)).fetchone() and self.store.db.execute("SELECT status FROM meeting_overview WHERE workspace_id=?",
            (self.workspace_id,)).fetchone()[0] == "ready")
        state = await self.service._snapshot(self.workspace_id, announce=False)
        overview = state["meeting_overview"]
        self.assertEqual(overview["status"], "ready")
        self.assertEqual(overview["data"]["discussion_points"][0]["evidence"], [
            {"segment_id": "public-example-product-1", "quote": speech}])
        self.assertEqual(state["tasks"], [])
        self.assertEqual(state["messages"], [])
        self.assertIsNone(self.store.workspace(self.workspace_id)["active_task_id"])
        task = self.store.db.execute("SELECT * FROM task WHERE kind='overview'").fetchone()
        self.assertEqual(task["lane"], "background")
        thread_id = task["thread_id"]
        self.assertEqual(self.fake.threads[thread_id]["sandbox"], "read-only")
        self.assertEqual(self.fake.threads[thread_id]["dynamic_tools"], [])
        turn = next(params for method, params in self.fake.requests if method == "turn/start")
        self.assertEqual(turn["outputSchema"], OVERVIEW_SCHEMA)
        prompt = turn["input"][0]["text"]
        self.assertIn(speech, prompt)
        self.assertNotIn("PRIVATE_NOTE_SHOULD_NOT_ENTER_OVERVIEW", prompt)
        self.assertNotIn("unfinished", prompt)
        await self.service.cmd_overview(self.workspace_id, {"active": False})

    async def test_overview_attempt_hash_never_makes_prior_result_look_current(self):
        speech_a = "团队不确定示例产品是否做过校园推广"
        speech_b = "随着它会主动调用 ai 江南春来写几句广告语。"
        await self.service.cmd_context(self.workspace_id, {"title": "Example Product", "segments": [
            {"id": "real-a", "text": speech_a, "final": True}]})
        hash_a = self.service._overview_hash(self.service.contexts[self.workspace_id])
        old_data = {"current_topic": {"text": speech_a, "evidence": [
                        {"segment_id": "real-a", "quote": speech_a}]},
                    "discussion_points": [], "decisions": [], "actions": [], "open_questions": []}
        self.service._set_overview_status(self.workspace_id, "ready", None, hash_a, old_data)

        await self.service.cmd_context(self.workspace_id, {"title": "Agent runtime", "segments": [
            {"id": "real-b", "text": speech_b, "final": True}]})
        hash_b = self.service._overview_hash(self.service.contexts[self.workspace_id])
        self.assertNotEqual(hash_a, hash_b)

        self.service._set_overview_status(self.workspace_id, "queued", None, hash_b)
        queued = await self.service._snapshot(self.workspace_id, announce=False)
        self.assertTrue(queued["meeting_overview"]["stale"])
        self.service._restore_overview_status_after_cancel(self.workspace_id)
        restored = await self.service._snapshot(self.workspace_id, announce=False)
        self.assertEqual(restored["meeting_overview"]["status"], "stale")
        self.assertTrue(restored["meeting_overview"]["stale"])

        for status in ("failed", "cancelled"):
            self.service._set_overview_status(self.workspace_id, status, "attempt_failed", hash_b)
            state = await self.service._snapshot(self.workspace_id, announce=False)
            row = self.store.db.execute("SELECT * FROM meeting_overview WHERE workspace_id=?",
                                        (self.workspace_id,)).fetchone()
            self.assertEqual(state["meeting_overview"]["status"], status)
            self.assertTrue(state["meeting_overview"]["stale"])
            self.assertEqual(row["source_hash"], hash_b)
            self.assertEqual(row["data_source_hash"], hash_a)
            self.assertEqual(json.loads(row["data_json"]), old_data)

        await self.service.cmd_context(self.workspace_id, {"segments": []})
        cleared = await self.service._snapshot(self.workspace_id, announce=False)
        self.assertTrue(cleared["meeting_overview"]["stale"])

    async def test_overview_tab_closed_prevents_automatic_calls(self):
        self.fake.auto_complete = False
        await self.service.cmd_context(self.workspace_id, {"title": "Example Product", "segments": [
            {"id": "public-example-product-1", "text": "团队不确定示例产品是否做过校园推广", "final": True}]})
        for index in range(2):
            task_id = self.service._create_task(self.workspace_id, f"占用后台{index}", "user", goal=f"busy {index}")
            self.service._set_task(task_id, status="running", lane="background")
            self.service.background_running.add(task_id)
        await self.service.cmd_overview(self.workspace_id, {"active": True})
        await self.wait_until(lambda: any(r["kind"] == "overview" and r["status"] == "queued"
                                          for r in self.store.tasks(self.workspace_id)))
        await self.service.cmd_overview(self.workspace_id, {"active": False})
        await asyncio.sleep(.03)
        task = next(r for r in self.store.tasks(self.workspace_id) if r["kind"] == "overview")
        self.assertEqual(task["status"], "cancelled")
        self.assertFalse(any(method == "turn/start" for method, _ in self.fake.requests))
        self.assertNotIn(task["id"], self.service.overview_inputs)

    async def test_overview_debounce_uses_30_second_quiet_and_60_second_max(self):
        now = [100.0]
        self.service.clock = lambda: now[0]
        delays = []
        gate = asyncio.Event()
        async def blocked_sleep(delay):
            delays.append(delay)
            await gate.wait()
        self.service.sleep = blocked_sleep
        self.service.overview_active.add(self.workspace_id)
        speech = "团队不确定示例产品是否做过校园推广"
        await self.service.cmd_context(self.workspace_id, {"title": "Example Product", "segments": [
            {"id": "public-example-product-1", "text": speech, "final": True}]})
        await self.wait_until(lambda: len(delays) == 1)
        self.assertEqual(delays[0], 30)
        now[0] = 140.0
        await self.service.cmd_context(self.workspace_id, {"title": "示例产品校园推广", "segments": [
            {"id": "public-example-product-1", "text": speech, "final": True}]})
        await self.wait_until(lambda: len(delays) == 2)
        self.assertEqual(delays[1], 20)
        await self.service.cmd_overview(self.workspace_id, {"active": False})
        gate.set()
        await asyncio.sleep(0)
        self.assertFalse(any(r["kind"] == "overview" for r in self.store.tasks(self.workspace_id)))

    async def test_overview_capacity_error_is_visible_and_retries_only_on_refresh(self):
        await self.service.cmd_context(self.workspace_id, {"title": "Example Product", "segments": [
            {"id": "public-example-product-1", "text": "团队不确定示例产品是否做过校园推广", "final": True}]})
        existing_ids = []
        for index in range(assistant_runtime.MAX_LIVE_TASKS):
            task_id = self.service._create_task(self.workspace_id, f"existing{index}", "user", goal=f"existing {index}")
            self.service._set_task(task_id, status="running")
            existing_ids.append(task_id)
        await self.service.cmd_overview(self.workspace_id, {"active": True})
        await self.wait_until(lambda: self.store.db.execute("SELECT status FROM meeting_overview WHERE workspace_id=?",
            (self.workspace_id,)).fetchone() and self.store.db.execute("SELECT status FROM meeting_overview WHERE workspace_id=?",
            (self.workspace_id,)).fetchone()[0] == "failed")
        row = self.store.db.execute("SELECT * FROM meeting_overview WHERE workspace_id=?", (self.workspace_id,)).fetchone()
        self.assertEqual(row["error"], "task_budget_exceeded")
        self.assertEqual(row["source_hash"], self.service._overview_hash(self.service.contexts[self.workspace_id]))
        self.assertFalse(any(r["kind"] == "overview" for r in self.store.tasks(self.workspace_id)))
        turns = sum(method == "turn/start" for method, _ in self.fake.requests)
        await self.service.cmd_overview(self.workspace_id, {"active": False})
        again = await self.service.cmd_overview(self.workspace_id, {"active": True})
        await asyncio.sleep(.03)
        self.assertFalse(again["queued"])
        self.assertEqual(sum(method == "turn/start" for method, _ in self.fake.requests), turns)
        forced = await self.service.cmd_overview(self.workspace_id, {"active": True, "refresh": True})
        await asyncio.sleep(.03)
        self.assertTrue(forced["active"])
        self.assertEqual(sum(method == "turn/start" for method, _ in self.fake.requests), turns)
        for task_id in existing_ids:
            self.service._set_task(task_id, status="completed")
        await self.service.cmd_overview(self.workspace_id, {"active": True, "refresh": True})
        await self.wait_until(lambda: self.store.db.execute("SELECT status FROM meeting_overview WHERE workspace_id=?",
            (self.workspace_id,)).fetchone()[0] == "ready")
        self.assertEqual(sum(method == "turn/start" for method, _ in self.fake.requests), turns + 1)

    async def test_overview_rejects_oversize_projection_and_preserves_prior_result(self):
        previous_limit = assistant_runtime.MAX_CONTEXT_CHARS
        assistant_runtime.MAX_CONTEXT_CHARS = 300
        try:
            speech = "团队不确定示例产品是否做过校园推广"
            await self.service.cmd_context(self.workspace_id, {"title": "Example Product", "segments": [
                {"id": "public-example-product-1", "text": speech, "final": True}]})
            ctx = self.service.contexts[self.workspace_id]
            prior = {"current_topic": {"text": "旧议题", "evidence": [{"segment_id": "public-example-product-1",
                "quote": "示例产品是否做过校园推广"}]}, "discussion_points": [], "decisions": [], "actions": [], "open_questions": []}
            self.service._set_overview_status(self.workspace_id, "ready", None, "old-hash", prior)
            self.service.overview_active.add(self.workspace_id)
            self.service.contexts[self.workspace_id] = {**ctx, "segments": [
                {"id": "public-example-product-1", "text": speech * 40, "final": True}]}
            self.service._schedule_overview(self.workspace_id, immediate=True)
            await self.wait_until(lambda: self.store.db.execute("SELECT status FROM meeting_overview WHERE workspace_id=?",
                (self.workspace_id,)).fetchone()[0] == "failed")
            row = self.store.db.execute("SELECT * FROM meeting_overview WHERE workspace_id=?", (self.workspace_id,)).fetchone()
            self.assertEqual(row["error"], "overview_too_long")
            self.assertEqual(json.loads(row["data_json"])["current_topic"]["text"], "旧议题")
            self.assertFalse(any(r["kind"] == "overview" for r in self.store.tasks(self.workspace_id)))
        finally:
            assistant_runtime.MAX_CONTEXT_CHARS = previous_limit

    async def test_overview_restart_marks_nonreplayable_task_interrupted(self):
        await self.service.cmd_context(self.workspace_id, {"title": "Example Product", "segments": [
            {"id": "public-example-product-1", "text": "团队不确定示例产品是否做过校园推广", "final": True}]})
        source_hash = self.service._overview_hash(self.service.contexts[self.workspace_id])
        task_id = self.service._create_task(self.workspace_id, "概览", "user", goal="overview",
                                            source_refs=[source_hash], kind="overview")
        self.service._set_task(task_id, status="running", thread_id="lost-thread")
        self.service._set_overview_status(self.workspace_id, "running", None, source_hash)
        self.store.close()
        reopened = AssistantStore(self.root / "store")
        recovered_runtime = FakeAppServer()
        offline = AssistantRuntime(reopened, self.root, runtime_factory=lambda **kw: recovered_runtime)
        try:
            await offline.bind("ignored", {"session_id": "session-1"})
            task = reopened.task(task_id)
            overview = reopened.db.execute("SELECT * FROM meeting_overview WHERE workspace_id=?",
                                           (self.workspace_id,)).fetchone()
            self.assertEqual(task["status"], "interrupted")
            self.assertEqual(overview["status"], "interrupted")
            self.assertEqual(overview["source_hash"], source_hash)
            await offline.cmd_context(self.workspace_id, {"title": "Example Product", "segments": [
                {"id": "public-example-product-1", "text": "团队不确定示例产品是否做过校园推广", "final": True}]})
            reopened_result = await offline.cmd_overview(self.workspace_id, {"active": True})
            self.assertFalse(reopened_result.get("queued"))
            self.assertEqual(overview["error"], "restart_no_replay")
            other = await offline.bind("other-overview-workspace", {"session_id": "session-2"})
            other_hash = "source-hash-without-result"
            completed = offline._create_task(other["workspace_id"], "概览", "user", goal="overview",
                                             source_refs=[other_hash], kind="overview")
            offline._set_task(completed, status="completed", thread_id="finished-thread")
            offline._set_overview_status(other["workspace_id"], "queued", None, other_hash)
            offline.recovered_workspaces.discard(other["workspace_id"])
            await offline._recover_threads(other["workspace_id"])
            resultless = reopened.db.execute("SELECT * FROM meeting_overview WHERE workspace_id=?",
                                             (other["workspace_id"],)).fetchone()
            self.assertEqual(resultless["status"], "failed")
            self.assertEqual(resultless["error"], "restart_result_missing")
        finally:
            await offline.shutdown()
            reopened.close()
            self.service._closed = True

    async def test_latest_completed_overview_task_controls_restart_recovery(self):
        speech = "团队不确定示例产品是否做过校园推广"
        await self.service.cmd_context(self.workspace_id, {"title": "Example Product", "segments": [
            {"id": "real-a", "text": speech, "final": True}]})
        older = self.service._create_task(self.workspace_id, "旧概览", "user", goal="older",
                                          source_refs=["hash-a"], kind="overview")
        newer = self.service._create_task(self.workspace_id, "新概览", "user", goal="newer",
                                          source_refs=["hash-b"], kind="overview")
        self.store.db.execute("UPDATE task SET status='completed',created=created+? WHERE id=?", (10, newer))
        self.service._set_task(older, status="completed")
        self.service._set_overview_status(self.workspace_id, "queued", None, "hash-b")
        self.store.close()
        self.service._closed = True

        reopened = AssistantStore(self.root / "store")
        recovered_runtime = FakeAppServer()
        recovered = AssistantRuntime(reopened, self.root, runtime_factory=lambda **kw: recovered_runtime)
        try:
            await recovered.bind("ignored", {"session_id": "session-1"})
            row = reopened.db.execute("SELECT status,source_hash FROM meeting_overview WHERE workspace_id=?",
                                      (self.workspace_id,)).fetchone()
            self.assertEqual(row["status"], "failed")
            self.assertEqual(row["source_hash"], "hash-b")
            self.assertEqual(reopened.task(older)["status"], "completed")
            self.assertEqual(reopened.task(newer)["status"], "completed")
        finally:
            await recovered.shutdown()
            reopened.close()

    async def test_failed_overview_same_hash_dedupes_after_context_rehydration_but_refresh_retries(self):
        speech = "团队不确定示例产品是否做过校园推广"
        params = {"title": "Example Product", "segments": [
            {"id": "public-example-product-1", "text": speech, "final": True}]}
        await self.service.cmd_context(self.workspace_id, params)
        source_hash = self.service._overview_hash(self.service.contexts[self.workspace_id])
        self.service._set_overview_status(self.workspace_id, "failed", "previous_failure", source_hash)
        self.service.overview_active.add(self.workspace_id)
        self.service.contexts.pop(self.workspace_id)

        await self.service.cmd_context(self.workspace_id, params)
        await asyncio.sleep(.03)
        self.assertFalse(any(row["kind"] == "overview" for row in self.store.tasks(self.workspace_id)))
        self.assertNotIn(self.workspace_id, self.service.overview_timers)

        await self.service.cmd_overview(self.workspace_id, {"active": True, "refresh": True})
        await self.wait_until(lambda: self.store.db.execute("SELECT status FROM meeting_overview WHERE workspace_id=?",
            (self.workspace_id,)).fetchone()[0] == "ready")
        self.assertEqual(sum(method == "turn/start" for method, _ in self.fake.requests), 1)
    async def test_overview_validation_drops_unverifiable_entries_and_rejects_unknown_ids(self):
        ctx = {"segments": [{"id": "s1", "speaker": "说话人乙", "text": "说话人乙 will review the notes tomorrow.", "final": True}]}
        data = {"current_topic": {"text": "Notes", "evidence": [{"segment_id": "s1", "quote": "review the notes"}]},
            "discussion_points": [{"text": "invented", "evidence": [{"segment_id": "fake", "quote": "invented"}]},
                                 {"text": "supported", "evidence": [{"segment_id": "s1", "quote": "review the notes"}]}],
            "decisions": [], "actions": [{"text": "Review notes", "owner": "说话人乙", "deadline": "tomorrow",
                "evidence": [{"segment_id": "s1", "quote": "will review the notes tomorrow."}]}], "open_questions": []}
        result = self.service._validate_overview(json.dumps(data), ctx)
        self.assertEqual([x["text"] for x in result["discussion_points"]], ["supported"])
        self.assertIsNone(result["actions"][0]["owner"])
        self.assertEqual(result["actions"][0]["deadline"], "tomorrow")
        data["actions"][0]["evidence"] = [{"segment_id": "s1", "quote": "说话人乙 will review the notes tomorrow."}]
        explicit_owner = self.service._validate_overview(json.dumps(data), ctx)
        self.assertEqual(explicit_owner["actions"][0]["owner"], "说话人乙")
        data["current_topic"]["evidence"] = [{"segment_id": "missing", "quote": "Notes"}]
        sanitized = self.service._validate_overview(json.dumps(data), ctx)
        self.assertEqual(sanitized["current_topic"]["text"], "")
        with self.assertRaisesRegex(ValueError, "overview_schema_invalid"):
            self.service._validate_overview(json.dumps({**data, "extra": "no"}), ctx)

    async def test_reserved_foreground_slot_and_bounded_background_parallelism(self):
        self.fake.auto_complete = False
        self.store.db.execute("UPDATE workspace SET proactive=1 WHERE id=?", (self.workspace_id,))
        bg_ids = []
        for i in range(2):
            tid = self.service._create_task(self.workspace_id, f"后台{i}", "proactive", goal=f"background goal {i}")
            self.service._message(f"bg-msg-{i}", tid, "user", f"background goal {i}", "queued", "proactive")
            bg_ids.append(tid)
        user_id = self.service._create_task(self.workspace_id, "前台问题", "user", goal="foreground")
        self.service._message("user-msg", user_id, "user", "foreground", "queued", "user")
        child_id = self.service._create_task(self.workspace_id, "并行用户子任务", "user", goal="child",
                                             parent_task_id=user_id, depth=1)
        self.service._message("child-msg", child_id, "user", "child", "queued", "user")
        self.service._pump()
        await self.wait_until(lambda: len(self.fake.thread_options) == 3)
        self.assertEqual(len(self.service.foreground_running), 1)
        self.assertEqual(len(self.service.background_running), 2)
        self.assertEqual(self.store.task(child_id)["status"], "queued")
        self.assertEqual(self.store.task(user_id)["status"], "running")

    async def test_new_user_root_tasks_use_background_slots_behind_reserved_foreground(self):
        self.fake.auto_complete = False
        first = self.service._create_task(self.workspace_id, "主任务", "user", goal="root")
        second = self.service._create_task(self.workspace_id, "并行任务", "user", goal="independent", depth=0)
        self.service._message("root-msg", first, "user", "root", "queued", "user")
        self.service._message("parallel-msg", second, "user", "parallel", "queued", "user")
        self.service._pump()
        await self.wait_until(lambda: len(self.fake.thread_options) == 2)
        self.assertEqual(self.store.task(first)["lane"], "foreground")
        self.assertEqual(self.store.task(second)["lane"], "background")
        self.assertEqual(len(self.service.foreground_running), 1)
        self.assertEqual(len(self.service.background_running), 1)

    async def test_dynamic_jobs_are_depth_and_global_budget_bounded(self):
        parent = self.service._create_task(self.workspace_id, "root", "user", goal="root")
        self.service._set_task(parent, thread_id="root-thread", status="running")
        row = self.store.task(parent)
        for index in range(7):
            self.service._create_task(self.workspace_id, f"queued {index}", "user", goal=str(index))
        result = await self.service._dynamic_tool(row, {"tool": "assistant_job_spawn",
            "arguments": {"title": "extra", "goal": "this exceeds the global task budget"}})
        self.assertFalse(result["success"])
        self.assertIn("task_budget_exceeded", result["contentItems"][0]["text"])

    async def test_turn_threads_are_separate_and_proactive_off_preserves_user_task(self):
        self.fake.auto_complete = False
        await self.service.cmd_proactive(self.workspace_id, {"enabled": True})
        user_id = self.service._create_task(self.workspace_id, "用户任务", "user", goal="foreground")
        self.service._message("u1", user_id, "user", "foreground", "queued", "user")
        bg_id = self.service._create_task(self.workspace_id, "主动任务", "proactive", goal="background")
        self.service._message("b1", bg_id, "user", "background", "queued", "proactive")
        self.service._pump()
        await self.wait_until(lambda: len(self.fake.thread_options) == 2)
        user_thread = self.store.task(user_id)["thread_id"]
        bg_thread = self.store.task(bg_id)["thread_id"]
        self.assertNotEqual(user_thread, bg_thread)
        await self.service.cmd_proactive(self.workspace_id, {"enabled": False})
        self.assertEqual(self.store.task(user_id)["status"], "running")
        await self.wait_until(lambda: self.store.task(bg_id)["status"] == "interrupted")
        self.assertIn(user_id, self.service.foreground_running)

    async def test_user_followup_takes_ownership_before_proactive_is_disabled(self):
        self.fake.auto_complete = False
        await self.service.cmd_proactive(self.workspace_id, {"enabled": True})
        task_id = self.service._create_task(self.workspace_id, "主动任务", "proactive", goal="background")
        self.service._set_task(task_id, thread_id="takeover-thread", turn_id="takeover-turn", status="running")
        await self.service.cmd_send(self.workspace_id, {"task_id": task_id, "text": "继续这个工作"})
        self.assertEqual(self.store.task(task_id)["origin"], "user")
        await self.service.cmd_proactive(self.workspace_id, {"enabled": False})
        self.assertEqual(self.store.task(task_id)["status"], "running")

    async def test_restart_marks_queued_work_interrupted_without_replay(self):
        task_id = self.service._create_task(self.workspace_id, "queued", "user", goal="not replayed")
        self.service._message("queued-message", task_id, "user", "not replayed", "queued", "user")
        self.store.close()
        reopened = AssistantStore(self.root / "store")
        replacement = FakeAppServer()
        service = AssistantRuntime(reopened, self.root, runtime_factory=lambda **kw: replacement)
        await service.bind("ignored", {"session_id": "session-1"})
        self.assertEqual(reopened.task(task_id)["status"], "interrupted")
        msg = reopened.db.execute("SELECT status FROM message WHERE id='queued-message'").fetchone()
        self.assertEqual(msg["status"], "interrupted")
        self.assertFalse(any(method == "turn/start" for method, _ in replacement.requests))
        await service.shutdown()
        reopened.close()
        # Prevent tearDown from using its already closed database.
        self.service._closed = True

    async def test_restart_quarantines_live_tasks_in_other_workspaces_before_pumping(self):
        other = await self.service.bind("workspace-two", {"session_id": "session-2"})
        other_id = other["workspace_id"]
        queued = self.service._create_task(other_id, "queued old", "user", goal="old queued")
        self.service._message("other-queued", queued, "user", "old queued", "queued", "user")
        running = self.service._create_task(other_id, "running old", "user", goal="old running")
        self.service._set_task(running, status="running", thread_id="old-thread", turn_id="old-turn")
        self.service._message("other-stream", running, "assistant", "partial", "streaming", "user")
        overview = self.service._create_task(other_id, "old overview", "user", goal="old overview", kind="overview")
        self.service._set_task(overview, status="waiting", thread_id="overview-thread")
        self.service._set_overview_status(other_id, "running", None, "old-source")
        self.store.close()
        reopened = AssistantStore(self.root / "store")
        replacement = FakeAppServer()
        service = AssistantRuntime(reopened, self.root, runtime_factory=lambda **kw: replacement)
        try:
            await service.bind("ignored", {"session_id": "session-1"})
            self.assertEqual(reopened.task(queued)["status"], "interrupted")
            self.assertEqual(reopened.task(running)["status"], "interrupted")
            self.assertEqual(reopened.task(overview)["status"], "interrupted")
            self.assertEqual(reopened.db.execute("SELECT status FROM message WHERE id='other-queued'").fetchone()[0], "interrupted")
            self.assertEqual(reopened.db.execute("SELECT status FROM message WHERE id='other-stream'").fetchone()[0], "interrupted")
            self.assertEqual(reopened.db.execute("SELECT status FROM meeting_overview WHERE workspace_id=?", (other_id,)).fetchone()[0], "interrupted")
            await service.cmd_send(self.workspace_id, {"text": "new workspace one request"})
            for _ in range(100):
                if any(method == "turn/start" for method, _ in replacement.requests):
                    break
                await asyncio.sleep(.005)
            started = [params["threadId"] for method, params in replacement.requests if method == "turn/start"]
            self.assertEqual(len(started), 1)
            self.assertNotIn("old-thread", started)
        finally:
            await service.shutdown()
            reopened.close()
            self.service._closed = True

    async def test_closed_runtime_reconnects_for_new_send_without_replaying_old_prompt(self):
        old_runtime = self.fake
        old_runtime.closed = True
        replacement = FakeAppServer()
        replacement.strict_resume = True
        self.service.runtime_factory = lambda **kw: replacement
        result = await self.service.cmd_send(self.workspace_id, {"text": "new request after reconnect"})
        await self.wait_until(lambda: self.store.task(result["task_id"])["status"] == "completed")
        self.assertEqual(replacement.start_count, 1)
        self.assertEqual(sum(method == "turn/start" for method, _ in replacement.requests), 1)
        self.assertEqual(self.store.task(result["task_id"])["status"], "completed")

    async def test_closed_runtime_resumes_selected_thread_before_new_followup(self):
        first = await self.service.cmd_send(self.workspace_id, {"text": "start conversation"})
        await self.wait_until(lambda: self.store.task(first["task_id"])["status"] == "completed")
        thread_id = self.store.task(first["task_id"])["thread_id"]
        old_runtime = self.fake
        old_runtime.closed = True
        replacement = FakeAppServer()
        replacement.strict_resume = True
        self.service.runtime_factory = lambda **kw: replacement
        second = await self.service.cmd_send(self.workspace_id, {"task_id": first["task_id"],
                                                                  "text": "continue after reconnect"})
        await self.wait_until(lambda: self.store.task(first["task_id"])["status"] == "completed"
                              and any(method == "turn/start" for method, _ in replacement.requests))
        self.assertEqual(second["task_id"], first["task_id"])
        self.assertIn(thread_id, replacement.resumed_threads)
        self.assertEqual(sum(method == "turn/start" for method, _ in replacement.requests), 1)
        self.assertEqual(self.store.db.execute("SELECT status FROM message WHERE id=?", (first["message_id"],)).fetchone()[0], "completed")
        self.assertEqual(self.store.db.execute("SELECT status FROM message WHERE id=?", (second["message_id"],)).fetchone()[0], "completed")

    async def test_reconnect_waits_for_old_worker_and_does_not_replay_its_queued_prompt(self):
        self.fake.auto_complete = False
        first = await self.service.cmd_send(self.workspace_id, {"text": "first turn"})
        await self.wait_until(lambda: any(method == "turn/start" for method, _ in self.fake.requests))
        thread_id = self.store.task(first["task_id"])["thread_id"]
        queued_old = await self.service.cmd_send(self.workspace_id, {"task_id": first["task_id"],
                                                                      "text": "queued before disconnect"})
        old_runtime = self.fake
        old_runtime.closed = True
        replacement = FakeAppServer()
        replacement.strict_resume = True
        self.service.runtime_factory = lambda **kw: replacement
        new_send = await self.service.cmd_send(self.workspace_id, {"task_id": first["task_id"],
                                                                    "text": "new after disconnect"})
        await self.wait_until(lambda: self.store.task(first["task_id"])["status"] == "completed")
        self.assertIn(thread_id, replacement.resumed_threads)
        self.assertEqual(sum(method == "turn/start" for method, _ in replacement.requests), 1)
        self.assertEqual(self.store.db.execute("SELECT status FROM message WHERE id=?", (queued_old["message_id"],)).fetchone()[0], "interrupted")
        self.assertEqual(self.store.db.execute("SELECT status FROM message WHERE id=?", (new_send["message_id"],)).fetchone()[0], "completed")

    async def test_cancelling_task_rejects_followups_and_late_approval(self):
        task_id = self.service._create_task(self.workspace_id, "cancelled work", "user", goal="work")
        self.service._set_task(task_id, status="cancelling", thread_id="cancel-thread", turn_id="cancel-turn")
        with self.assertRaisesRegex(RuntimeErrorCode, "task_cancelling"):
            await self.service.cmd_send(self.workspace_id, {"task_id": task_id, "text": "must not queue"})
        actor = self.service._create_task(self.workspace_id, "actor", "user", goal="actor")
        self.service._set_task(actor, status="running", thread_id="actor-thread")
        result = await self.service._dynamic_tool(self.store.task(actor), {"tool": "assistant_job_continue",
            "arguments": {"task_id": task_id, "text": "also must not queue"}})
        self.assertFalse(result["success"])
        self.assertIn("task_cancelling", result["contentItems"][0]["text"])
        self.assertFalse(self.store.db.execute("SELECT 1 FROM message WHERE task_id=? AND text='must not queue'", (task_id,)).fetchone())
        response = await self.service._on_server_request("item/commandExecution/requestApproval", {
            "_serverRequestId": 808, "threadId": "cancel-thread", "command": "late approval"})
        self.assertEqual(response, {"decision": "decline"})
        self.assertFalse(self.service.approvals)

    async def test_cancel_during_approval_history_read_declines_late_request(self):
        entered = asyncio.Event()
        release = asyncio.Event()
        class SlowReadServer(FakeAppServer):
            async def read_thread(self, thread_id):
                entered.set()
                await release.wait()
                return {"thread": {"id": thread_id, "turns": []}}
        slow = SlowReadServer()
        self.service.runtime = slow
        task_id = self.service._create_task(self.workspace_id, "late approval", "user", goal="approval")
        self.service._set_task(task_id, status="running", thread_id="late-thread")
        request = asyncio.create_task(self.service._on_server_request("item/fileChange/requestApproval", {
            "_serverRequestId": 809, "threadId": "late-thread", "itemId": "not-loaded"}))
        await entered.wait()
        self.service._set_task(task_id, status="cancelling")
        release.set()
        self.assertEqual(await request, {"decision": "decline"})
        self.assertFalse(self.service.approvals)

    async def test_pump_does_not_duplicate_registered_worker_or_clear_new_worker(self):
        task_id = self.service._create_task(self.workspace_id, "queued", "user", goal="queued")
        self.service._message("pump-queued", task_id, "user", "queued", "queued", "user")
        gate = asyncio.Event()
        original_worker = asyncio.create_task(gate.wait())
        self.service.task_workers[task_id] = original_worker
        self.service._pump()
        self.assertEqual(self.store.task(task_id)["status"], "queued")
        replacement_worker = asyncio.create_task(gate.wait())
        self.service.task_workers[task_id] = replacement_worker
        self.service._worker_done(task_id, original_worker)
        self.assertIs(self.service.task_workers[task_id], replacement_worker)
        gate.set()
        await asyncio.gather(original_worker, replacement_worker)
        self.service.task_workers.pop(task_id, None)

    async def test_dynamic_task_tools_create_independent_worker_without_reply_focus(self):
        self.store.db.execute("UPDATE workspace SET proactive=1 WHERE id=?", (self.workspace_id,))
        parent = self.service._create_task(self.workspace_id, "parent", "proactive", goal="parent")
        self.service._set_task(parent, thread_id="parent-thread", status="running")
        row = self.store.task(parent)
        result = await self.service._dynamic_tool(row, {"tool": "assistant_job_spawn",
            "arguments": {"title": "查校园推广", "goal": "检索项目历史，确认是否做过校园推广案例"}})
        self.assertTrue(result["success"])
        tasks = self.store.tasks(self.workspace_id)
        child = next(t for t in tasks if t["id"] != parent)
        self.assertEqual(child["origin"], "proactive")
        self.assertEqual(child["status"], "running")
        self.assertIsNone(self.store.workspace(self.workspace_id)["active_task_id"])
        self.assertEqual(len(self.service._dynamic_tools()), 4)

    async def test_proactive_dynamic_tools_cannot_control_user_owned_tasks(self):
        proactive = self.service._create_task(self.workspace_id, "observer", "proactive", goal="observe")
        self.service._set_task(proactive, thread_id="observer-thread", status="running")
        user = self.service._create_task(self.workspace_id, "user work", "user", goal="user owned")
        self.service._set_task(user, thread_id="user-thread", turn_id="active", status="running")
        actor = self.store.task(proactive)
        continue_result = await self.service._dynamic_tool(actor, {"tool": "assistant_job_continue",
            "arguments": {"task_id": user, "text": "take over"}})
        cancel_result = await self.service._dynamic_tool(actor, {"tool": "assistant_job_cancel",
            "arguments": {"task_id": user}})
        self.assertFalse(continue_result["success"])
        self.assertFalse(cancel_result["success"])
        self.assertIn("task_origin_forbidden", continue_result["contentItems"][0]["text"])
        self.assertIn("task_origin_forbidden", cancel_result["contentItems"][0]["text"])
        self.assertEqual(self.store.task(user)["status"], "running")

    async def test_native_approval_request_is_routed_to_its_task(self):
        task_id = self.service._create_task(self.workspace_id, "approval", "user", goal="approval")
        self.service._set_task(task_id, thread_id="approval-thread", status="running")
        await self.service._handle_event(task_id, "item/started", {"item": {
            "id": "approval-item", "type": "fileChange",
            "changes": [{"kind": "update", "path": "report.md", "diff": "+approved content"}]}})
        pending = asyncio.create_task(self.service._on_server_request("item/fileChange/requestApproval", {
            "_serverRequestId": 57, "threadId": "approval-thread", "turnId": "t1",
            "itemId": "approval-item", "reason": "save report"}))
        await self.wait_until(lambda: len(self.service.approvals) == 1)
        approval_id = next(iter(self.service.approvals))
        approval = self.service.approvals[approval_id]
        self.assertEqual(approval["task_id"], task_id)
        await self.service.cmd_approval(self.workspace_id, {"approval_id": approval_id, "decision": "accept"})
        self.assertEqual(await pending, {"decision": "accept"})

    async def test_file_change_approval_shows_actual_path_and_diff(self):
        task_id = self.service._create_task(self.workspace_id, "approval", "user", goal="approval")
        self.service._set_task(task_id, thread_id="approval-thread", status="running")
        await self.service._handle_event(task_id, "item/started", {"item": {
            "id": "file-item", "type": "fileChange", "status": "pending",
            "changes": [{"kind": "update", "path": "notes.md", "diff": "@@ -1 +1 @@\n-old\n+new"}]}})
        pending = asyncio.create_task(self.service._on_server_request("item/fileChange/requestApproval", {
            "_serverRequestId": 58, "threadId": "approval-thread", "turnId": "t1",
            "itemId": "file-item", "reason": "update notes"}))
        await self.wait_until(lambda: len(self.service.approvals) == 1)
        approval_id, approval = next(iter(self.service.approvals.items()))
        state = await self.service._snapshot(self.workspace_id, announce=False)
        self.assertEqual(state["approvals"][0]["kind"], "file_change")
        self.assertIn("notes.md", approval["detail"])
        self.assertIn("+new", approval["detail"])
        await self.service.cmd_approval(self.workspace_id, {"approval_id": approval_id, "decision": "accept"})
        self.assertEqual(await pending, {"decision": "accept"})

    async def test_file_change_without_diff_is_unknown_and_cannot_be_accepted(self):
        task_id = self.service._create_task(self.workspace_id, "approval", "user", goal="approval")
        self.service._set_task(task_id, thread_id="approval-thread", status="running")
        pending = asyncio.create_task(self.service._on_server_request("item/fileChange/requestApproval", {
            "_serverRequestId": 59, "threadId": "approval-thread", "turnId": "t1",
            "itemId": "missing-item", "reason": "update notes"}))
        await self.wait_until(lambda: len(self.service.approvals) == 1)
        approval_id, approval = next(iter(self.service.approvals.items()))
        self.assertEqual(approval["kind"], "unknown")
        with self.assertRaisesRegex(ValueError, "approval_details_missing"):
            await self.service.cmd_approval(self.workspace_id, {"approval_id": approval_id, "decision": "accept"})
        await self.service.cmd_approval(self.workspace_id, {"approval_id": approval_id, "decision": "decline"})
        self.assertEqual(await pending, {"decision": "decline"})

    async def test_file_change_approval_reads_existing_thread_item_when_event_was_missed(self):
        class ExistingChangeAppServer(FakeAppServer):
            async def read_thread(self, thread_id):
                return {"thread": {"id": thread_id, "turns": [{"items": [{
                    "id": "persisted-change", "type": "fileChange", "status": "pending",
                    "changes": [{"kind": "update", "path": "summary.md", "diff": "@@ -0,0 +1 @@\n+summary"}]}]}]}}

        runtime = ExistingChangeAppServer()
        self.service.runtime = runtime
        task_id = self.service._create_task(self.workspace_id, "approval", "user", goal="approval")
        self.service._set_task(task_id, thread_id="approval-thread", status="running")
        pending = asyncio.create_task(self.service._on_server_request("item/fileChange/requestApproval", {
            "_serverRequestId": 60, "threadId": "approval-thread", "turnId": "t1",
            "itemId": "persisted-change"}))
        await self.wait_until(lambda: len(self.service.approvals) == 1)
        approval_id, approval = next(iter(self.service.approvals.items()))
        self.assertEqual(approval["kind"], "file_change")
        self.assertIn("summary.md", approval["detail"])
        self.assertIn("+summary", approval["detail"])
        await self.service.cmd_approval(self.workspace_id, {"approval_id": approval_id, "decision": "decline"})
        self.assertEqual(await pending, {"decision": "decline"})

    async def test_user_input_answers_are_normalized_per_question(self):
        self.assertEqual(AssistantRuntime._approval_result("tool/requestUserInput", "accept", {
            "q1": "Keep the current title", "q2": ["A", "B"]}),
            {"answers": {"q1": {"answers": ["Keep the current title"]},
                          "q2": {"answers": ["A", "B"]}}})
        self.assertEqual(AssistantRuntime._approval_result("tool/requestUserInput", "decline", {
            "q1": "ignored"}), {"answers": {}})

    async def test_stale_prior_turn_completion_cannot_end_current_turn(self):
        task_id = self.service._create_task(self.workspace_id, "turn filter", "user", goal="filter")
        self.service._set_task(task_id, thread_id="filter-thread", status="running")
        queue = self.fake.events.setdefault("filter-thread", asyncio.Queue())
        await queue.put({"method": "turn/completed", "params": {"threadId": "filter-thread",
            "turn": {"id": "old-turn", "status": "interrupted"}}})
        await self.service._run_turn(task_id, "filter-thread", "continue")
        self.assertEqual(self.store.task(task_id)["status"], "running")

    async def test_fast_completion_before_interrupt_reply_is_not_overwritten(self):
        release_interrupt = asyncio.Event()
        interrupt_entered = asyncio.Event()

        class SlowInterrupt(FakeAppServer):
            async def interrupt(self, thread_id, turn_id):
                await self.events.setdefault(thread_id, asyncio.Queue()).put({"method": "turn/completed",
                    "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed"}}})
                interrupt_entered.set()
                await release_interrupt.wait()
                return {}

        runtime = SlowInterrupt(auto_complete=False)
        self.service.runtime = runtime
        task_id = self.service._create_task(self.workspace_id, "fast completion", "user", goal="race")
        self.service._set_task(task_id, thread_id="race-thread", status="running")
        turn_task = asyncio.create_task(self.service._run_turn(task_id, "race-thread", "run once"))
        await self.wait_until(lambda: bool(self.store.task(task_id)["turn_id"]))
        cancel_task = asyncio.create_task(self.service._cancel_task(task_id, reason="test_cancel"))
        await interrupt_entered.wait()
        await turn_task
        self.assertEqual(self.store.task(task_id)["status"], "completed")
        release_interrupt.set()
        await cancel_task
        self.assertEqual(self.store.task(task_id)["status"], "completed")

    async def test_unknown_native_request_is_not_granted(self):
        with self.assertRaisesRegex(RuntimeErrorCode, "unknown_server_request_declined"):
            await self.service._on_server_request("future/unknown", {"threadId": "none"})

    async def test_scout_is_debounced_read_only_and_uses_structured_output(self):
        delays = []

        async def instant_sleep(delay):
            delays.append(delay)
            await asyncio.sleep(0)

        service = AssistantRuntime(self.store, self.root, runtime_factory=lambda **kw: self.fake,
                                   emit=self.service.emit_callback, sleep=instant_sleep)
        service.runtime = self.fake
        self.store.db.execute("UPDATE workspace SET proactive=1 WHERE id=?", (self.workspace_id,))
        await service.cmd_context(self.workspace_id, {"title": "strategy", "segments": [
            {"id": "seg-1", "revision": 1, "text": "We are unsure whether the example product has run campus marketing.", "final": True}]})
        await self.wait_until(lambda: any(r["origin"] == "scout" and r["status"] == "completed" for r in self.store.tasks(self.workspace_id)))
        turn = next(params for method, params in self.fake.requests if method == "turn/start")
        scout_thread = self.store.db.execute("SELECT thread_id FROM task WHERE origin='scout'").fetchone()[0]
        options = self.fake.threads[scout_thread]
        self.assertEqual(options["sandbox"], "read-only")
        self.assertEqual(turn["outputSchema"], SCOUT_SCHEMA)
        self.assertAlmostEqual(delays[0], 10, places=3)
        await service.shutdown()
        self.service._closed = True

    async def test_send_cannot_route_to_another_workspace_task(self):
        other = await self.service.bind("other-workspace", {"session_id": "session-2"})
        foreign_task = self.service._create_task(other["workspace_id"], "private", "user", goal="secret")
        with self.assertRaisesRegex(ValueError, "task_not_found"):
            await self.service.cmd_send(self.workspace_id, {"task_id": foreign_task, "text": "continue"})

    async def test_offline_bind_does_not_construct_or_launch_codex(self):
        calls = []

        def forbidden_factory(**kwargs):
            calls.append(kwargs)
            raise AssertionError("offline mode must not create a Codex runtime")

        offline = AssistantRuntime(self.store, self.root, offline=True, runtime_factory=forbidden_factory)
        result = await offline.bind("offline-workspace", {"session_id": "offline-session"})
        self.assertEqual(result["state"]["runtime_status"], "offline")
        self.assertEqual(calls, [])
        with self.assertRaisesRegex(ValueError, "runtime_offline"):
            await offline.cmd_send(result["workspace_id"], {"text": "no network"})
        await offline.cmd_context(result["workspace_id"], {"segments": [
            {"id": "public-example-product-1", "text": "团队不确定示例产品是否做过校园推广", "final": True}]})
        unavailable = await offline.cmd_overview(result["workspace_id"], {"active": True})
        self.assertFalse(unavailable["available"])
        self.assertEqual((await offline._snapshot(result["workspace_id"], announce=False))["meeting_overview"]["error"],
                         "runtime_offline")


if __name__ == "__main__":
    unittest.main()


class ProtocolFramingTests(unittest.IsolatedAsyncioTestCase):
    async def test_actual_project_text_larger_than_default_stream_limit(self):
        material = (Path(__file__).parents[1] / "README.md").read_text()
        payload = json.dumps({"method": "context", "params": {"notes": material * 20}}, ensure_ascii=False).encode() + b"\n"
        self.assertGreater(len(payload), 65536)
        reader = asyncio.StreamReader(limit=assistant_runtime.MAX_PROTOCOL_LINE_BYTES)
        reader.feed_data(payload); reader.feed_eof()
        self.assertEqual(await assistant_runtime._read_protocol_line(reader), (payload, False))
        self.assertEqual(await assistant_runtime._read_protocol_line(reader), (b"", False))

    async def test_oversized_command_drain_preserves_following_command(self):
        payload = (Path(__file__).parents[1] / "README.md").read_text().replace("\n", " ").encode() + b"\n"
        following = b'{"method":"shutdown"}\n'
        reader = asyncio.StreamReader(limit=128)
        reader.feed_data(payload + following); reader.feed_eof()
        self.assertTrue((await assistant_runtime._read_protocol_line(reader))[1])
        self.assertEqual(await assistant_runtime._read_protocol_line(reader), (following, False))

    async def test_oversized_unterminated_command_reaches_eof(self):
        payload = (Path(__file__).parents[1] / "README.md").read_text().replace("\n", " ").encode()
        reader = asyncio.StreamReader(limit=128)
        reader.feed_data(payload); reader.feed_eof()
        self.assertTrue((await assistant_runtime._read_protocol_line(reader))[1])
        self.assertEqual(await assistant_runtime._read_protocol_line(reader), (b"", False))
