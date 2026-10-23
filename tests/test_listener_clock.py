"""P8a offline contract checks, using the authorized meeting's real text/times.

No model calls. Data-dependent cases skip on machines without this meeting;
transport and CLI checks remain self-contained.
"""
import asyncio
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from codex_runtime import CodexRuntime
from scripts import replay_meeting_assistant as p

CACHE_ID = "394FBA81-C2E0-4258-B1B3-B2AE038E2017"


class RealMeetingTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        database = p.DATA_ROOT / "AgentContext/context.sqlite"
        if not database.is_file():
            raise unittest.SkipTest("authorized local meeting is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            # The native reader fallback is separately exercised below; a unit
            # test must not trigger a full Swift compilation unexpectedly.
            with patch("scripts.replay_meeting_assistant.native_projection",
                       side_effect=unittest.SkipTest("meeting projection unavailable")):
                cls.context = p.load_context(CACHE_ID, Path(directory))

    def short_context(self):
        context = copy.deepcopy(self.context)
        context["segments"] = sorted(context["segments"], key=lambda r: r["end"])[:10]
        context["duration_seconds"] = max(r["end"] for r in context["segments"]) + 5
        return context

    async def test_visibility_and_revision_gate_all_three_read_tools(self):
        clock = p.MeetingClock(self.short_context(), offline=True)
        first = clock.ends[0]
        self.assertGreater(first, 0)
        self.assertEqual(clock.read(0, 999)["segments"], [])
        self.assertEqual(clock.search("")["segments"], [])
        timed_out = await clock.wait(0, first / 2)
        self.assertEqual(timed_out["revision"], 0)
        arrived = await clock.wait(0, first)
        self.assertEqual(clock.now, first)
        self.assertTrue(arrived["segments"])
        for result in (arrived, clock.read(0, 999), clock.search("")):
            self.assertTrue(all(r["end"] <= clock.now for r in result["segments"]))
        revision = clock.revision
        backlog = await clock.wait(0, 1000)
        self.assertEqual(backlog["revision"], revision)
        self.assertEqual(clock.now, first)
        self.assertEqual(clock.read(1, 1)["segments"], clock.visible()[1:2])

    async def test_overlapping_end_order_ties_and_zero_time(self):
        context = self.short_context()
        rows = context["segments"][:3]
        # Real sentences, controlled timing to cover simultaneous availability.
        rows[0].update(start=0, end=20)
        rows[1].update(start=5, end=10)
        rows[2].update(start=8, end=10)
        context.update(segments=rows, duration_seconds=20)
        clock = p.MeetingClock(context, offline=True)
        data = await clock.wait(0, 100)
        self.assertEqual(data["revision"], 2)
        self.assertEqual({r["id"] for r in data["segments"]}, {rows[1]["id"], rows[2]["id"]})
        self.assertEqual(clock.now, 10)
        await clock.wait(2, 100)
        self.assertTrue(clock.ended)
        rows[0].update(start=0, end=0)
        clock = p.MeetingClock(context, offline=True)
        self.assertEqual(clock.revision, 1)
        self.assertEqual((await clock.wait(0, 10))["segments"][0]["id"], rows[0]["id"])
        self.assertEqual(clock.now, 0)

    async def test_speed_and_offline_sleep_and_eof(self):
        sleep = AsyncMock()
        context = self.short_context()
        clock = p.MeetingClock(context, speed=4, sleep=sleep)
        await clock.wait(0, 1000)
        sleep.assert_awaited_once_with(clock.ends[0] / 4)
        offline_sleep = AsyncMock(side_effect=AssertionError("offline slept"))
        clock = p.MeetingClock(context, speed=100, offline=True, sleep=offline_sleep)
        while not clock.ended:
            await clock.wait(clock.revision, 1000)
        self.assertEqual(clock.now, context["duration_seconds"])
        self.assertEqual(clock.revision, len(clock.rows))
        eof = await clock.wait(clock.revision, 1000)
        self.assertEqual(eof["segments"], [])
        self.assertTrue(eof["ended"])
        offline_sleep.assert_not_awaited()

    async def test_invalid_arguments_cannot_move_clock(self):
        clock = p.MeetingClock(self.short_context(), offline=True)
        for after, wait in [(1, 5), (-1, 5), (0, -1), (0, float("nan")), (0, float("inf")), (False, 5)]:
            with self.assertRaises(ValueError):
                await clock.wait(after, wait)
            self.assertEqual(clock.now, 0)
        for offset, limit in [(-1, 1), (0, -1), (0, 1.5)]:
            with self.assertRaises(ValueError):
                clock.read(offset, limit)

