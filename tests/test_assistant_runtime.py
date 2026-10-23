import asyncio
import hashlib
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

import assistant_runtime
from assistant_runtime import AssistantRuntime, AssistantStore, OVERVIEW_SCHEMA
from codex_runtime import RuntimeErrorCode


class FakeAppServer:
    """In-process protocol adapter: deterministic events, no network/model calls."""

    def __init__(self, *, auto_complete=True, on_request=None):
        self.auto_complete = auto_complete
        self.on_request = on_request
        self.started = False
        self.start_count = 0
        self.closed = False
        self.failure = None
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
                prompt = params["input"][0]["text"]
                source_rows = [json.loads(line) for line in prompt.split("最终发言片段：\n", 1)[1].splitlines()]
                source_id = next((str(row[0]) for row in source_rows if isinstance(row[2], str)
                                  and "不知道 qoder 有没有做过校园的推广" in row[2]), "0")
                text = json.dumps({"current_topic": {"text": "Qoder 校园推广", "evidence": [
                    {"segment_id": source_id, "quote": "qoder 有没有做过校园的推广"}]},
                    "discussion_points": [{"text": "团队尚不确定 Qoder 是否做过校园推广", "evidence": [
                        {"segment_id": source_id, "quote": "不知道 qoder 有没有做过校园的推广"}]}],
                    "decisions": [], "actions": [], "open_questions": [{"text": "Qoder 是否做过校园推广？", "evidence": [
                        {"segment_id": source_id, "quote": "qoder 有没有做过校园的推广"}]}]}, ensure_ascii=False)
            else:
                text = json.dumps({"stance": "代表团队明确校园推广目标", "items": []}, ensure_ascii=False)
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


    async def test_meeting_overview_uses_codex_schema_without_changing_chat_focus(self):
        speech = "不知道 qoder 有没有做过校园的推广"
        await self.service.cmd_context(self.workspace_id, {"title": "Qoder campus marketing", "notes": "PRIVATE_NOTE_SHOULD_NOT_ENTER_OVERVIEW",
            "segments": [{"id": "public-qoder-1", "revision": 1, "text": speech, "speaker": "Bob", "final": True},
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
            {"segment_id": "public-qoder-1", "quote": speech}])
        self.assertNotIn("tasks", state)
        self.assertEqual(state["messages"], [])
        self.assertIsNone(self.store.workspace(self.workspace_id)["active_task_id"])
        task = self.store.db.execute("SELECT * FROM task WHERE kind='overview'").fetchone()
        self.assertEqual(task["lane"], "background")
        thread_id = task["thread_id"]
        self.assertTrue(self.fake.threads[thread_id]["ephemeral"])
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
        speech_a = "不知道 qoder 有没有做过校园的推广"
        speech_b = "随着它会主动调用 ai 示例人物39来写几句广告语。"
        await self.service.cmd_context(self.workspace_id, {"title": "Qoder", "segments": [
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

    async def test_overview_tab_closed_does_not_cancel_queued_job(self):
        self.fake.auto_complete = False
        await self.service.cmd_context(self.workspace_id, {"title": "Qoder", "segments": [
            {"id": "public-qoder-1", "text": "不知道 qoder 有没有做过校园的推广", "final": True}]})
        for index in range(2):
            other = await self.service.bind(f"busy-{index}", {})
            task_id = self.service._create_task(other["workspace_id"], f"占用后台{index}", "user", goal=f"busy {index}", kind="overview")
            self.service._set_task(task_id, status="running", lane="background")
            self.service.background_running.add(task_id)
        await self.service.cmd_overview(self.workspace_id, {"active": True})
        await self.wait_until(lambda: any(r["kind"] == "overview" and r["status"] == "queued"
                                          for r in self.store.tasks(self.workspace_id)))
        await self.service.cmd_overview(self.workspace_id, {"active": False})
        await asyncio.sleep(.03)
        task = next(r for r in self.store.tasks(self.workspace_id) if r["kind"] == "overview")
        self.assertEqual(task["status"], "queued")
        self.assertFalse(any(method == "turn/start" for method, _ in self.fake.requests))
        self.assertIn(task["id"], self.service.overview_inputs)



    async def test_overview_compact_projection_keeps_all_rows_and_restores_full_ids(self):
        # Public product requirements, with the observed long meeting's row count.
        segments = [{"id": f"00000000-0000-0000-0000-000000000000:1:word:{index}",
                     "text": "概览只读，不允许审批和工具。", "speaker": f"声音来源{index % 9}",
                     "final": True} for index in range(1376)]
        segments[700]["text"] = "不知道 qoder 有没有做过校园的推广"
        segments[0].update(speaker="", speaker_uncertain=True)
        segments[1].update(quality_flags=["audio_timing_mismatch"])
        ctx = {"title": "侧栏需求", "segments": segments + [{"id": "unfinished", "text": "尚未完成", "final": False}]}
        prompt = self.service._overview_prompt(ctx)
        rows = [json.loads(line) for line in prompt.split("最终发言片段：\n")[1].splitlines()]
        self.assertLessEqual(len(prompt), assistant_runtime.MAX_CONTEXT_CHARS)
        self.assertEqual(len(rows), 1376)
        self.assertEqual([row[0] for row in rows], list(range(1376)))
        self.assertEqual(rows[0][2], segments[0]["text"])
        self.assertEqual(rows[-1][2], segments[-1]["text"])
        self.assertIsNone(rows[1][2])
        self.assertIn('["",true]', prompt)
        self.assertNotIn("尚未完成", prompt)
        await self.service.cmd_context(self.workspace_id, ctx)
        await self.service.cmd_overview(self.workspace_id, {"active": True})
        await self.wait_until(lambda: self.store.db.execute("SELECT 1 FROM meeting_overview WHERE workspace_id=? AND status='ready'",
            (self.workspace_id,)).fetchone() is not None)
        stored = self.store.db.execute("SELECT data_json FROM meeting_overview WHERE workspace_id=?",
            (self.workspace_id,)).fetchone()[0]
        evidence = json.loads(stored)["current_topic"]["evidence"]
        self.assertEqual(evidence[0]["segment_id"], segments[700]["id"])
        self.assertEqual(sum(method == "turn/start" for method, _ in self.fake.requests), 1)

    async def test_overview_index_protocol_rejects_wrong_sources_and_keeps_numeric_ids_unambiguous(self):
        ctx = {"overview_source_format": assistant_runtime.OVERVIEW_SOURCE_FORMAT, "segments": [
            {"id": "1", "text": "概览必须保留精确原文证据。", "final": True},
            {"id": "0", "text": "笔记需要保留用户的编辑。", "final": True},
            {"id": "bad", "text": "坏原文仍应保留。", "quality_flags": ["audio_corrupt"], "final": True}]}
        def validate(sid, quote, source=ctx):
            data = {"current_topic": {"text": "侧栏需求", "evidence": [{"segment_id": sid, "quote": quote}]},
                    "discussion_points": [], "decisions": [], "actions": [], "open_questions": []}
            return self.service._validate_overview(json.dumps(data), source)["current_topic"]["evidence"]
        quote = ctx["segments"][0]["text"]
        self.assertEqual(validate("0", quote), [{"segment_id": "1", "quote": quote}])
        for sid in ("3", "-1", "00", "foreign-meeting-id", "bad"):
            self.assertEqual(validate(sid, quote), [])
        self.assertEqual(validate("0", "伪造原文"), [])
        self.assertEqual(validate("2", ctx["segments"][2]["text"]), [])
        other = {**ctx, "segments": [{"id": "other-meeting", "text": "另一场会议的原文。", "final": True}]}
        self.assertEqual(validate("0", quote, other), [])
        legacy = {"segments": ctx["segments"]}
        legacy_quote = ctx["segments"][1]["text"]
        self.assertEqual(validate("0", legacy_quote, legacy), [{"segment_id": "0", "quote": legacy_quote}])

    async def test_overview_indices_resolve_against_frozen_input_after_context_changes(self):
        quote = "概览必须保留精确原文证据。"
        frozen = {"overview_source_format": assistant_runtime.OVERVIEW_SOURCE_FORMAT,
                  "segments": [{"id": "original-first", "text": quote, "final": True}]}
        task_id = self.service._create_task(self.workspace_id, "概览", "user", kind="overview")
        self.service.overview_inputs[task_id] = frozen
        self.service.contexts[self.workspace_id] = {"segments": [
            {"id": "new-first", "text": "新的发言。", "final": True}, *frozen["segments"]]}
        data = {"current_topic": {"text": "概览证据", "evidence": [{"segment_id": "0", "quote": quote}]},
                "discussion_points": [], "decisions": [], "actions": [], "open_questions": []}
        self.service._message("indexed-result", task_id, "assistant", json.dumps(data), "complete", "user")
        await self.service._finish_overview(task_id)
        row = self.store.db.execute("SELECT status,data_json FROM meeting_overview WHERE workspace_id=?",
                                   (self.workspace_id,)).fetchone()
        self.assertEqual(row["status"], "stale")
        self.assertEqual(json.loads(row["data_json"])["current_topic"]["evidence"],
                         [{"segment_id": "original-first", "quote": quote}])

    async def test_overview_new_format_retries_persisted_legacy_too_long_without_manual_refresh(self):
        ctx = {"title": "Qoder", "segments": [
            {"id": "public-qoder-1", "text": "不知道 qoder 有没有做过校园的推广", "final": True}]}
        await self.service.cmd_context(self.workspace_id, ctx)
        legacy_material = {"evidence_policy": 3, "title": ctx["title"], "segments": [
            {"id": "public-qoder-1", "text": ctx["segments"][0]["text"], "speaker": "",
             "quality_flags": [], "speaker_uncertain": False, "text_quality": None}]}
        old_hash = hashlib.sha256(assistant_runtime._compact(legacy_material).encode()).hexdigest()
        self.assertNotEqual(old_hash, self.service._overview_hash(ctx))
        self.service._set_overview_status(self.workspace_id, "failed", "overview_too_long", old_hash)
        async def immediate_sleep(delay):
            await asyncio.sleep(0)
        self.service.sleep = immediate_sleep
        result = await self.service.cmd_overview(self.workspace_id, {"active": True})
        self.assertTrue(result["queued"])
        await self.wait_until(lambda: self.store.db.execute("SELECT status FROM meeting_overview WHERE workspace_id=?",
            (self.workspace_id,)).fetchone()[0] == "ready")
        self.assertEqual(sum(method == "turn/start" for method, _ in self.fake.requests), 1)



    async def test_overview_restart_marks_nonreplayable_task_interrupted(self):
        await self.service.cmd_context(self.workspace_id, {"title": "Qoder", "segments": [
            {"id": "public-qoder-1", "text": "不知道 qoder 有没有做过校园的推广", "final": True}]})
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
            await offline.cmd_context(self.workspace_id, {"title": "Qoder", "segments": [
                {"id": "public-qoder-1", "text": "不知道 qoder 有没有做过校园的推广", "final": True}]})
            reopened_result = await offline.cmd_overview(self.workspace_id, {"active": True})
            self.assertFalse(reopened_result.get("queued"))
            self.assertEqual(overview["error"], "restart_no_replay")
            other = await offline.bind("other-overview-workspace", {"session_id": "session-2"})
            other_hash = "source-hash-without-result"
            completed = offline._create_task(other["workspace_id"], "概览", "user", goal="overview",
                                             source_refs=[other_hash], kind="overview")
            offline._set_task(completed, status="completed", thread_id="finished-thread")
            offline._set_overview_status(other["workspace_id"], "queued", None, other_hash)
            offline._recover_persisted_work()
            resultless = reopened.db.execute("SELECT * FROM meeting_overview WHERE workspace_id=?",
                                             (other["workspace_id"],)).fetchone()
            self.assertEqual(resultless["status"], "failed")
            self.assertEqual(resultless["error"], "restart_result_missing")
        finally:
            await offline.shutdown()
            reopened.close()
            self.service._closed = True

    async def test_latest_completed_overview_task_controls_restart_recovery(self):
        speech = "不知道 qoder 有没有做过校园的推广"
        await self.service.cmd_context(self.workspace_id, {"title": "Qoder", "segments": [
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
        speech = "不知道 qoder 有没有做过校园的推广"
        params = {"title": "Qoder", "segments": [
            {"id": "public-qoder-1", "text": speech, "final": True}]}
        await self.service.cmd_context(self.workspace_id, params)
        source_hash = self.service._overview_hash(self.service.contexts[self.workspace_id])
        self.service._set_overview_status(self.workspace_id, "failed", "previous_failure", source_hash)
        self.service.contexts.pop(self.workspace_id)

        await self.service.cmd_context(self.workspace_id, params)
        await asyncio.sleep(.03)
        self.assertFalse(any(row["kind"] == "overview" for row in self.store.tasks(self.workspace_id)))
        self.assertNotIn(self.workspace_id, self.service.overview_timers)

        await self.service.cmd_overview(self.workspace_id, {"active": True, "refresh": True})
        await self.wait_until(lambda: self.store.db.execute("SELECT status FROM meeting_overview WHERE workspace_id=?",
            (self.workspace_id,)).fetchone()[0] == "ready")
        self.assertEqual(sum(method == "turn/start" for method, _ in self.fake.requests), 1)
    async def test_overview_company_names_do_not_prove_payment_relation(self):
        source = "我们常规邀请的是甲公司和乙公司。"
        ctx = {"segments": [{"id": "company", "text": source, "final": True}]}
        data = {"current_topic": {"text": "支付方式", "evidence": [{"segment_id": "company", "quote": source}]},
                "discussion_points": [{"text": "常规支持这两种支付渠道", "evidence": [{"segment_id": "company", "quote": source}]}],
                "decisions": [], "actions": [], "open_questions": []}
        result = self.service._validate_overview(json.dumps(data), ctx)
        self.assertEqual(result["current_topic"], {"text": "", "evidence": []})
        self.assertEqual(result["discussion_points"], [])
        payment = "我们支持信用卡支付。"
        ctx["segments"][0]["text"] = payment
        for item in [data["current_topic"], data["discussion_points"][0]]:
            item["evidence"][0]["quote"] = payment
        accepted = self.service._validate_overview(json.dumps(data), ctx)
        self.assertEqual(len(accepted["discussion_points"]), 1)


    async def test_overview_all_unreliable_input_does_not_start_model(self):
        ctx = {"segments": [{"id": "fragment", "text": "不。", "final": True},
                            {"id": "bad", "text": "仍然保留的原文", "final": True,
                             "quality_flags": ["audio_timing_mismatch"]}]}
        self.service.contexts[self.workspace_id] = ctx
        before = len(self.fake.requests)
        await self.service._start_overview_after_delay(self.workspace_id, 0)
        row = self.store.db.execute("SELECT status,error FROM meeting_overview WHERE workspace_id=?",
                                    (self.workspace_id,)).fetchone()
        self.assertEqual((row["status"], row["error"]), ("failed", "overview_no_reliable_evidence"))
        self.assertEqual(len(self.fake.requests), before)
        self.assertFalse(any(t["kind"] == "overview" for t in self.store.tasks(self.workspace_id)))

    async def test_overview_filtered_claim_is_visible_and_next_valid_result_clears_warning(self):
        source = "我们常规邀请的是甲公司和乙公司。"
        ctx = {"segments": [{"id": "company", "text": source, "final": True}]}
        self.service.contexts[self.workspace_id] = ctx
        data = {"current_topic": {"text": "支付方式", "evidence": [{"segment_id": "company", "quote": source}]},
                "discussion_points": [], "decisions": [], "actions": [], "open_questions": []}
        for index, (label, warning) in enumerate([("支付方式", "overview_evidence_filtered"), ("受邀企业", None)]):
            data["current_topic"]["text"] = label
            task_id = self.service._create_task(self.workspace_id, "概览", "user", kind="overview")
            self.service.overview_inputs[task_id] = ctx
            self.service._message(f"overview-warning-{index}", task_id, "assistant",
                                  json.dumps(data), "complete", "user")
            await self.service._finish_overview(task_id)
            row = self.store.db.execute("SELECT status,error,data_json FROM meeting_overview WHERE workspace_id=?",
                                        (self.workspace_id,)).fetchone()
            self.assertEqual(row["status"], "ready")
            self.assertEqual(row["error"], warning)
            if warning:
                self.assertEqual(json.loads(row["data_json"])["current_topic"]["text"], "")

    async def test_overview_excludes_corrupt_and_objectless_evidence(self):
        ctx = {"segments": [
            {"id": "fragment", "text": "不。", "final": True},
            {"id": "noise", "text": "本次会议讨论的是活动参加情况以及安排。ちちち。反复内容。にとる。", "final": True},
            {"id": "flagged", "text": "The company will attend.", "final": True, "quality_flags": ["language_shift_needs_review"]},
            {"id": "company", "text": "我们正在沟通甲公司是否参加北京这次活动。", "final": True},
            {"id": "japanese", "text": "こんにちは。次の会議では企業参加状況及び共同宣伝計画について確認します。", "final": True}]}
        data = {"current_topic": {"text": "活动", "evidence": [{"segment_id": "company", "quote": ctx["segments"][3]["text"]}]},
                "discussion_points": [{"text": "对方拒绝", "evidence": [{"segment_id": "fragment", "quote": "不。"}]},
                                      {"text": "错误业务内容", "evidence": [{"segment_id": "noise", "quote": "本次会议讨论的是活动参加情况以及安排。"}]}],
                "decisions": [{"text": "已定参会", "evidence": [{"segment_id": "flagged", "quote": "The company will attend."}]}],
                "actions": [], "open_questions": []}
        result = self.service._validate_overview(json.dumps(data), ctx)
        self.assertEqual(result["discussion_points"], [])
        self.assertEqual(result["decisions"], [])
        self.assertEqual(result["current_topic"]["text"], "活动")
        prompt = self.service._overview_prompt(ctx)
        self.assertNotIn("ちちち", prompt)
        self.assertIn("こんにちは", prompt)
        self.assertIn("不得依据常识", prompt)
        self.assertIn("speaker_uncertain", prompt)
        changed = {"segments": [dict(ctx["segments"][3], quality_flags=["audio_corrupt"])]}
        unflagged = {"segments": [ctx["segments"][3]]}
        self.assertNotEqual(self.service._overview_hash(changed), self.service._overview_hash(unflagged))

    async def test_overview_validation_drops_unverifiable_entries_and_rejects_unknown_ids(self):
        ctx = {"segments": [{"id": "s1", "speaker": "Bob", "text": "Bob will review the notes tomorrow.", "final": True}]}
        data = {"current_topic": {"text": "Notes", "evidence": [{"segment_id": "s1", "quote": "review the notes"}]},
            "discussion_points": [{"text": "invented", "evidence": [{"segment_id": "fake", "quote": "invented"}]},
                                 {"text": "supported", "evidence": [{"segment_id": "s1", "quote": "review the notes"}]}],
            "decisions": [], "actions": [{"text": "Review notes", "owner": "Bob", "deadline": "tomorrow",
                "evidence": [{"segment_id": "s1", "quote": "will review the notes tomorrow."}]}], "open_questions": []}
        result = self.service._validate_overview(json.dumps(data), ctx)
        self.assertEqual([x["text"] for x in result["discussion_points"]], ["supported"])
        self.assertIsNone(result["actions"][0]["owner"])
        self.assertEqual(result["actions"][0]["deadline"], "tomorrow")
        data["actions"][0]["evidence"] = [{"segment_id": "s1", "quote": "Bob will review the notes tomorrow."}]
        explicit_owner = self.service._validate_overview(json.dumps(data), ctx)
        self.assertEqual(explicit_owner["actions"][0]["owner"], "Bob")
        data["current_topic"]["evidence"] = [{"segment_id": "missing", "quote": "Notes"}]
        sanitized = self.service._validate_overview(json.dumps(data), ctx)
        self.assertEqual(sanitized["current_topic"]["text"], "")
        with self.assertRaisesRegex(ValueError, "overview_schema_invalid"):
            self.service._validate_overview(json.dumps({**data, "extra": "no"}), ctx)





















    async def test_long_preview_preserves_binding_notes_and_budget(self):
        request = "尤其是新的右边侧边栏的三个功能助理、概览和笔记"
        ctx = {"title": "在场侧栏检查", "session_id": "session-1", "cache_id": "cache-1",
               "context_database": str(self.root / "context.sqlite"), "notes": request,
               "segments": [{"id": "long-segment", "text": request * 3000}]}
        text = self.service._context_text(ctx)
        self.assertLessEqual(len(text), assistant_runtime.MAX_CONTEXT_CHARS)
        self.assertIn("session_id=session-1; cache_id=cache-1", text)
        self.assertIn(ctx["context_database"], text)
        self.assertIn("User notes:\n" + request, text)
        self.assertIn("Transcript preview truncated", text)
        self.assertTrue(text.endswith(request))

    async def test_segment_limit_reports_omitted_speech_even_when_short(self):
        ctx = {"title": "侧栏检查", "segments": [
            {"id": str(i), "text": "检查"} for i in range(101)]}
        text = self.service._context_text(ctx)
        self.assertIn("Transcript preview truncated", text)
        self.assertNotIn("[0 ]", text)
        self.assertIn("[100 ] 检查", text)

    async def test_long_title_cannot_evict_meeting_references(self):
        text = self.service._context_text({"title": "侧栏" * 30000,
            "session_id": "session-1", "cache_id": "cache-1", "segments": []})
        self.assertLessEqual(len(text), assistant_runtime.MAX_CONTEXT_CHARS)
        self.assertIn("session_id=session-1; cache_id=cache-1", text)















    async def test_offline_bind_does_not_construct_or_launch_codex(self):
        calls = []

        def forbidden_factory(**kwargs):
            calls.append(kwargs)
            raise AssertionError("offline mode must not create a Codex runtime")

        offline = AssistantRuntime(self.store, self.root, offline=True, runtime_factory=forbidden_factory)
        result = await offline.bind("offline-workspace", {"session_id": "offline-session"})
        self.assertEqual(result["state"]["runtime_status"], "offline")
        self.assertEqual(calls, [])
        with self.assertRaisesRegex(RuntimeErrorCode, "runtime_offline"):
            await offline.cmd_send(result["workspace_id"], {"text": "no network"})
        await offline.cmd_context(result["workspace_id"], {"segments": [
            {"id": "public-qoder-1", "text": "不知道 qoder 有没有做过校园的推广", "final": True}]})
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
