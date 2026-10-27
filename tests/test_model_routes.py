import asyncio
import unittest
from unittest.mock import AsyncMock
from codex_runtime import CodexRuntime
from tests.test_incremental_overview import MeetingIncrementalOverviewTests

class RouteTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_only_new_thread_is_pinned_and_permissions_unchanged(self):
        runtime=CodexRuntime();runtime.request=AsyncMock(return_value={'thread':{'id':'test'}})
        await runtime.start_thread('/tmp',model='gpt-6.1-terra',effort='medium',sandbox='read-only',approval_policy='never')
        sent=runtime.request.await_args.args[1]
        self.assertEqual(sent['model'],'gpt-6.1-terra')
        self.assertEqual(sent['config']['model_reasoning_effort'],'medium')
        self.assertEqual(sent['sandbox'],'read-only')
        await runtime.start_turn('existing','existing user selection retained')
        sent=runtime.request.await_args.args[1]
        self.assertNotIn('model',sent);self.assertNotIn('effort',sent)

class PurposeRoutes(MeetingIncrementalOverviewTests):
    async def test_overview_requests_medium_terra(self):
        await self.context(1);await self.settle()
        options=self.fake.thread_options[0]
        # Fake transport records the exact options used by the real scheduler.
        if isinstance(options,tuple):options=options[-1]
        self.assertEqual(options['model'],'gpt-6.1-terra')
        self.assertEqual(options['effort'],'medium')
