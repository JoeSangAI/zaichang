"""P2 scheduler/validation contract, synthetic meeting data, no model or live stores."""
import asyncio
import copy
import json
import unittest
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

    async def context(self, count):
        await self.service.cmd_context(self.workspace_id, {"title": "Qoder 校园推广", "segments": self.segments(count)})

    def row(self):
        return self.store.db.execute("SELECT * FROM meeting_overview WHERE workspace_id=?", (self.workspace_id,)).fetchone()

    async def test_background_without_tab_and_active_false_keeps_running(self):
        self.fake.auto_complete = False
        await self.context(1)
        await self.wait_until(lambda: any(r["kind"] == "overview" and r["turn_id"] for r in self.store.tasks(self.workspace_id)))
        task = next(r for r in self.store.tasks(self.workspace_id) if r["kind"] == "overview")
        await self.service.cmd_overview(self.workspace_id, {"active": False})
        self.assertEqual(self.store.task(task["id"])["status"], "running")
        self.assertTrue(self.service.overview_inputs)

    async def test_600_chars_or_180_seconds_with_new_content(self):
        now = [1000.0]; self.service.clock = lambda: now[0]
        await self.context(1); await self.settle()
        delays = []; gate = asyncio.Event()
        async def sleep(delay):
            delays.append(delay); await gate.wait()
        self.service.sleep = sleep
        now[0] += 20
        await self.context(2)
        await self.wait_until(lambda: bool(delays))
        self.assertEqual(delays, [160])
        await self.context(15); await self.settle()
        self.assertEqual(len(json.loads(self.row()["covered_json"])), 15)
        before = len(self.fake.requests)
        self.service._schedule_overview(self.workspace_id)
        await asyncio.sleep(.01)
        self.assertEqual(len(self.fake.requests), before)
        now[0] += 181
        await self.context(16); await self.settle()
        self.assertEqual(len(json.loads(self.row()["covered_json"])), 16)

    async def test_full_then_incremental_batches_persist_coverage_and_old_evidence(self):
        await self.context(1); await self.settle()
        prior = json.loads(self.row()["data_json"])
        with patch.object(ar, "MAX_CONTEXT_CHARS", 2200):
            await self.context(70); await self.settle()
            row = self.row()
            self.assertEqual(len(json.loads(row["covered_json"])), 70)
            self.assertEqual(row["status"], "ready")
            self.assertGreater(len([r for r in self.store.tasks(self.workspace_id) if r["kind"] == "overview"]), 2)
            prompts = [p["input"][0]["text"] for m,p in self.fake.requests if m == "turn/start"]
            self.assertTrue(all(len(p) <= 2200 for p in prompts))
            self.assertIn("上一版概览", prompts[-1])
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
                parts += [json.loads(line)[2] for line in frozen["prompt"].split("最终发言片段：\n")[1].splitlines()]
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
        ctx["segments"][0].pop("quality_flags"); data["discussion_points"][0]["evidence"][0]["quote"]="不在原文的引用"
        self.assertEqual(ar.AssistantRuntime._validate_overview(ar._compact(data),ctx)["discussion_points"],[])

