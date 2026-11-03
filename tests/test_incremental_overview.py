"""P2 scheduler/validation contract, synthetic meeting data, no model or live stores."""
import asyncio
import copy
import io
import json
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

import assistant_runtime as ar
from tests import test_assistant_runtime as fixtures


class MeetingIncrementalOverviewTests(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = fixtures.AssistantRuntimeTests.asyncSetUp
    asyncTearDown = fixtures.AssistantRuntimeTests.asyncTearDown
    wait_until = fixtures.AssistantRuntimeTests.wait_until

    def segments(self, count=1):
        return [{"id": f"speech-{i}", "final": True, "speaker": "Bob", "revision": 1,
                 "text": f"第{i}项：不知道 qoder 有没有做过校园的推广。我们需要了解学校合作的具体条件、预算边界与负责人。"}
                for i in range(count)]

    async def settle(self):
        await self.wait_until(lambda: not self.service.overview_timers and not self.service.task_workers)

    async def context(self, count, state="paused", segments=None):
        await self.service.cmd_context(self.workspace_id, {"title": "Qoder 校园推广", "meeting_state": state,
                                                           "segments": segments or self.segments(count)})

    def overview_runs(self):
        return [r for r in self.store.tasks(self.workspace_id) if r["kind"] == "overview"]

    def row(self):
        return self.store.db.execute("SELECT * FROM meeting_overview WHERE workspace_id=?", (self.workspace_id,)).fetchone()

    async def test_background_without_tab_and_active_false_keeps_running(self):
        self.overview_model.gate = asyncio.Event()
        await self.context(1)
        await self.wait_until(lambda: bool(self.overview_model.calls))
        task = next(r for r in self.store.tasks(self.workspace_id) if r["kind"] == "overview")
        await self.service.cmd_overview(self.workspace_id, {"active": False})
        self.assertEqual(self.store.task(task["id"])["status"], "running")
        self.assertTrue(self.service.overview_inputs)
        self.overview_model.gate.set()

    async def test_one_clock_whatever_changed(self):
        now = [1000.0]; self.service.clock = lambda: now[0]
        await self.context(1, "recording"); await self.settle()
        delays = []; gate = asyncio.Event()
        async def sleep(delay):
            delays.append(delay); await gate.wait()
        self.service.sleep = sleep
        now[0] += 20
        await self.context(2, "recording")
        await self.wait_until(lambda: bool(delays))
        self.assertEqual(delays, [160])
        # A lot of new speech and a corrected speaker wait for the same moment.
        now[0] += 20
        await self.context(40, "recording")
        corrected = self.segments(40); corrected[0]["speaker"] = "Alice"
        await self.context(0, "recording", corrected)
        await asyncio.sleep(.01)
        self.assertEqual(delays, [160])
        self.assertEqual(len(self.overview_runs()), 1)
        # When the moment comes it reads whatever is latest.
        now[0] += 181; gate.set(); await self.settle()
        self.assertEqual(len(self.overview_runs()), 2)
        self.assertEqual(len(json.loads(self.row()["covered_json"])), 40)

    async def test_bookkeeping_is_not_a_change(self):
        now = [1000.0]; self.service.clock = lambda: now[0]
        await self.context(3, "recording"); await self.settle()
        now[0] += 500
        batch = self.segments(3)
        for segment in batch:
            segment.update(revision=9, end=12.5)
        await self.context(0, "recording", batch); await self.settle()
        self.assertEqual(len(self.overview_runs()), 1)
        state = await self.service._snapshot(self.workspace_id, announce=False)
        self.assertFalse(state["meeting_overview"]["stale"])

    async def test_recording_stop_runs_without_waiting(self):
        now = [1000.0]; self.service.clock = lambda: now[0]
        await self.context(1, "recording"); await self.settle()
        now[0] += 10
        await self.context(2, "recording")
        await self.context(2, "stopped"); await self.settle()
        self.assertEqual(len(self.overview_runs()), 2)
        await self.context(2, "stopped"); await self.settle()
        self.assertEqual(len(self.overview_runs()), 2)

    async def test_network_failure_retries_on_the_interval_and_recovers(self):
        now = [1000.0]; self.service.clock = lambda: now[0]
        self.overview_model.failure = "model_unreachable"
        delays = []; gate = asyncio.Event()
        async def sleep(delay):
            delays.append(delay); await gate.wait()
        self.service.sleep = sleep
        await self.context(1, "stopped")
        await self.wait_until(lambda: bool(delays))
        self.assertEqual(delays, [180])
        self.assertEqual(self.row()["error"], "model_unreachable")
        self.overview_model.failure = None; self.service.sleep = asyncio.sleep
        now[0] += 181; gate.set(); await self.settle()
        self.assertEqual(self.row()["status"], "ready")
        self.assertIsNone(self.row()["error"])

    async def test_overview_starts_no_codex_and_ignores_process_limit(self):
        self.service.headroom = lambda: 0
        self.fake.start_count = 0
        await self.context(1, "stopped"); await self.settle()
        self.assertEqual(self.row()["status"], "ready")
        self.assertEqual(self.fake.thread_options, [])
        self.assertEqual(self.fake.start_count, 0)

    async def test_overview_works_with_no_codex_at_all(self):
        def absent(**options):
            raise fixtures.RuntimeErrorCode("codex_not_installed")
        await self.service.runtime.close()
        self.service.runtime = None; self.service.runtime_factory = absent
        await self.service.bind(self.workspace_id, {"session_id": "session-1", "cache_id": "cache-1"})
        state = await self.service._snapshot(self.workspace_id, announce=False)
        self.assertEqual(state["runtime_status"], "auth_required")
        self.assertIn("概览、转写和纪要不受影响", state["runtime_message"])
        await self.context(1, "stopped"); await self.settle()
        self.assertEqual(self.row()["status"], "ready")
        response = await self.service.dispatch({"id": "1", "method": "send", "workspace_id": self.workspace_id, "params": {"text": "你好"}})
        self.assertFalse(response["ok"])
        self.assertIn("使用引导", response["error"]["message"])
        response = await self.service.dispatch({"id": "2", "method": "proactive", "workspace_id": self.workspace_id, "params": {"enabled": True}})
        self.assertFalse(response["ok"])
        self.assertIn("使用引导", response["error"]["message"])
        self.assertEqual(self.store.workspace(self.workspace_id)["proactive"], 0)

    async def test_key_waits_silently_until_the_app_has_said(self):
        self.service.overview_key = None
        await self.context(1, "stopped"); await asyncio.sleep(.01)
        self.assertIsNone(self.row())
        await self.service.dispatch({"id": "1", "method": "overview_key", "params": {"key": "new-key"}}); await self.settle()
        self.assertEqual(self.row()["status"], "ready")
        self.assertEqual(self.overview_model.calls[0]["key"], "new-key")

    async def test_missing_key_is_named_and_a_new_key_retries_at_once(self):
        self.service.overview_key = ""
        await self.context(1, "stopped"); await self.settle()
        self.assertEqual((self.row()["status"], self.row()["error"]), ("failed", "overview_key_missing"))
        self.assertEqual(self.overview_model.calls, [])
        result = await self.service.dispatch({"id": "1", "method": "overview_key", "params": {"key": "new-key"}}); await self.settle()
        self.assertEqual(result["result"], {"available": True})
        self.assertEqual(self.row()["status"], "ready")

    async def test_rejected_key_does_not_retry_until_it_changes(self):
        self.overview_model.failure = "overview_key_rejected"
        await self.context(1, "stopped"); await self.settle()
        self.assertEqual(self.row()["error"], "overview_key_rejected")
        await self.context(1, "stopped"); await self.settle()
        self.assertEqual(len(self.overview_model.calls), 1)
        self.overview_model.failure = None
        await self.service.set_overview_key({"key": "better-key"}); await self.settle()
        self.assertEqual(self.row()["status"], "ready")

    async def test_key_stays_out_of_store_logs_and_state(self):
        secret = "sk-never-persist-this"
        with self.assertNoLogs("assistant_runtime", level="ERROR"):
            await self.service.set_overview_key({"key": secret})
            with self.assertLogs("assistant_runtime", level="WARNING") as logs:
                await self.context(1, "stopped"); await self.settle()
        self.assertNotIn(secret, "\n".join(logs.output))
        self.assertTrue(any("zaichang-overview-usage" in line for line in logs.output))
        self.assertNotIn(secret, json.dumps(await self.service._snapshot(self.workspace_id, announce=False)))
        dump = "\n".join(self.store.db.iterdump())
        self.assertNotIn(secret, dump)

    async def test_unparseable_reply_fails_without_retrying_the_same_text(self):
        async def garbage(key, prompt, timeout):
            return {"text": "这不是 JSON", "model": "deepseek-v4.1-flash", "usage": None}
        calls = []
        async def counted(key, prompt, timeout):
            calls.append(prompt); return await garbage(key, prompt, timeout)
        self.service.overview_call = counted
        await self.context(1, "stopped"); await self.settle()
        self.assertEqual(self.row()["error"], "overview_response_invalid")
        await self.context(1, "stopped"); await self.settle()
        self.assertEqual(len(calls), 1)

    async def test_full_then_incremental_batches_persist_coverage_and_old_evidence(self):
        await self.context(1); await self.settle()
        prior = json.loads(self.row()["data_json"])
        with patch.object(ar, "MAX_CONTEXT_CHARS", 2200):
            await self.context(70, "recording")
            await self.context(70, "stopped"); await self.settle()
            row = self.row()
            self.assertEqual(len(json.loads(row["covered_json"])), 70)
            self.assertEqual(row["status"], "ready")
            self.assertGreater(len([r for r in self.store.tasks(self.workspace_id) if r["kind"] == "overview"]), 2)
            prompts = [call["prompt"] for call in self.overview_model.calls]
            self.assertTrue(all(len(p) <= 2200 for p in prompts))
            self.assertIn("上一版概览", prompts[-1])
            # Only incremental rounds carry the keep-previous reminder, after the new speech.
            self.assertTrue(prompts[-1].endswith(ar.OVERVIEW_KEEP_REMINDER))
            self.assertNotIn(ar.OVERVIEW_KEEP_REMINDER, prompts[0])
            self.assertIn(prior["current_topic"]["evidence"][0]["segment_id"], prompts[1])
            self.assertNotIn("overview_too_long", str(row["error"]))
            state = await self.service._snapshot(self.workspace_id, announce=False)
            self.assertFalse(state["meeting_overview"]["stale"])

    async def test_oversized_single_utterance_is_split_losslessly(self):
        body = "".join(f"第{i}项校园推广计划需要各方明确目标。" for i in range(200))
        ctx = {"segments": [{"id": "long", "final": True, "text": body}]}
        parts = []
        with patch.object(ar, "MAX_CONTEXT_CHARS", 1800):
            for _ in range(30):
                frozen = self.service._prepare_overview(self.workspace_id, ctx)
                self.assertLessEqual(len(frozen["prompt"]), 1800)
                self.assertTrue(frozen["prompt"].endswith(ar.OVERVIEW_KEEP_REMINDER))
                new_lines = frozen["prompt"].removesuffix(ar.OVERVIEW_KEEP_REMINDER).split("最终发言片段：\n")[1]
                parts += [json.loads(line)[2] for line in new_lines.splitlines()]
                self.service._set_overview_status(self.workspace_id, "ready", None, "x")
                self.store.db.execute("UPDATE meeting_overview SET covered_json=?", (ar._compact(frozen["covered"]),))
                if not frozen["remaining"]: break
            self.assertFalse(frozen["remaining"])
            self.assertEqual("".join(parts), body)

    async def test_incremental_validates_old_ids_current_quality_and_exact_quote(self):
        ctx = {"segments": self.segments(3)}
        data = copy.deepcopy(ar.EMPTY_OVERVIEW)
        data["discussion_points"] = [{"text": "学校合作条件", "evidence": [{"segment_id": "speech-0", "quote": "学校合作的具体条件"}]}]
        self.assertEqual(ar.AssistantRuntime._validate_overview(ar._compact(data),ctx)["discussion_points"],data["discussion_points"])
        ctx["segments"][0]["quality_flags"] = ["needs_review"]
        self.assertEqual(ar.AssistantRuntime._validate_overview(ar._compact(data),ctx)["discussion_points"],[])
        ctx["segments"][0].pop("quality_flags")
        # Long original IDs get miscopied; words found verbatim in exactly one line correct the pointer.
        miscopied = {"segment_id":"speech-9-miscopied","quote":"第1项：不知道"}
        data["discussion_points"][0]["evidence"][0]=miscopied
        self.assertEqual(ar.AssistantRuntime._validate_overview(ar._compact(data),ctx)["discussion_points"][0]["evidence"],
                         [{"segment_id":"speech-1","quote":"第1项：不知道"}])
        # Words in more than one line prove nothing about which one was meant.
        data["discussion_points"][0]["evidence"][0]={"segment_id":"speech-9-miscopied","quote":"学校合作的具体条件"}
        self.assertEqual(ar.AssistantRuntime._validate_overview(ar._compact(data),ctx)["discussion_points"],[])
        data["discussion_points"][0]["evidence"][0]={"segment_id":"speech-0","quote":"不在原文的引用"}
        self.assertEqual(ar.AssistantRuntime._validate_overview(ar._compact(data),ctx)["discussion_points"],[])


class FakeOpener:
    def __init__(self, outcome):
        self.outcome, self.request = outcome, None

    def open(self, request, timeout=None):
        self.request, self.timeout = request, timeout
        if isinstance(self.outcome, Exception):
            raise self.outcome
        return self

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, size=-1):
        return self.outcome


def http_error(code, body=b""):
    return urllib.error.HTTPError(ar.OVERVIEW_API_URL, code, "x", {}, io.BytesIO(body))


class BailianClientTests(unittest.TestCase):
    def call(self, outcome):
        opener = FakeOpener(outcome)
        with patch.object(ar.urllib.request, "build_opener", return_value=opener):
            return ar._call_overview_model("secret-key", "会议原文", 60), opener

    def test_request_is_json_object_without_thinking_and_keeps_the_meeting_last(self):
        reply = json.dumps({"model": "deepseek-v4.1-flash", "usage": {"prompt_tokens": 9}, "choices": [
            {"finish_reason": "stop", "message": {"content": "{}"}}]}).encode()
        result, opener = self.call(reply)
        self.assertEqual(result, {"text": "{}", "model": "deepseek-v4.1-flash", "usage": {"prompt_tokens": 9}})
        body = json.loads(opener.request.data)
        self.assertEqual(opener.request.full_url, "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        self.assertEqual(body["model"], "deepseek-v4.1-flash")
        self.assertEqual(body["response_format"], {"type": "json_object"})
        self.assertIs(body["enable_thinking"], False)
        self.assertIn("JSON", body["messages"][0]["content"])
        self.assertEqual(body["messages"][1], {"role": "user", "content": "会议原文"})
        self.assertEqual(opener.timeout, 60)

    def test_proxy_failure_goes_direct_once(self):
        good = json.dumps({"choices": [{"finish_reason": "stop", "message": {"content": "{}"}}]}).encode()
        openers = [FakeOpener(urllib.error.URLError("Tunnel connection failed: 503")), FakeOpener(good)]
        built = []
        def build(*handlers):
            built.append(handlers); return openers[len(built) - 1]
        with patch.object(ar.urllib.request, "build_opener", side_effect=build):
            self.assertEqual(ar._call_overview_model("k", "p", 60)["text"], "{}")
        self.assertEqual(len(built), 2)
        self.assertFalse(any(isinstance(h, ar.urllib.request.ProxyHandler) for h in built[0]))
        self.assertEqual(next(h for h in built[1] if isinstance(h, ar.urllib.request.ProxyHandler)).proxies, {})

    def test_an_answer_from_the_service_is_not_retried(self):
        opener = FakeOpener(http_error(429))
        with patch.object(ar.urllib.request, "build_opener", return_value=opener) as build:
            with self.assertRaises(ar.RuntimeErrorCode):
                ar._call_overview_model("k", "p", 60)
        self.assertEqual(build.call_count, 1)

    def test_failures_are_codes_never_provider_text(self):
        for outcome, code in [
                (http_error(401), "overview_key_rejected"), (http_error(403), "overview_key_rejected"),
                (http_error(400, b'{"error":{"code":"Arrearage","message":"echo"}}'), "overview_key_rejected"),
                (http_error(400, b'{"error":{"code":"data_inspection_failed","message":"echo"}}'), "overview_content_rejected"),
                (http_error(400, b'{"error":{"code":"invalid_parameter_error"}}'), "overview_request_rejected"),
                (http_error(429), "model_unreachable"), (http_error(503), "model_unreachable"),
                (urllib.error.URLError("no route"), "model_unreachable"), (TimeoutError(), "model_unreachable"),
                (b"not json", "overview_response_invalid"), (b'{"choices":[]}', "overview_response_invalid"),
                (json.dumps({"choices": [{"finish_reason": "length", "message": {"content": "{"}}]}).encode(), "overview_response_invalid")]:
            with self.subTest(code=code), self.assertRaises(ar.RuntimeErrorCode) as caught:
                self.call(outcome)
            self.assertEqual(caught.exception.code, code)
            self.assertNotIn("echo", str(caught.exception))
