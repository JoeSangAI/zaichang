"""P8 lifecycle tests: real project text, in-process transport, no model or live writes."""
import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

from assistant_runtime import AssistantRuntime, AssistantStore
from codex_runtime import CodexRuntime, RuntimeErrorCode
from tests.test_assistant_runtime import FakeAppServer


class ListenerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = AssistantStore(self.tmp.name)
        self.fake = FakeAppServer(); self.fake.auto_complete = False
        self.fake.steer = AsyncMock(return_value={})
        self.fake.interrupt = AsyncMock(wraps=self.fake.interrupt)
        self.service = AssistantRuntime(self.store, Path.cwd(), runtime_factory=lambda **kw: self.fake)
        self.service._schedule_overview = lambda *a, **kw: None
        self.service.wait_batch_seconds = .03
        await self.service.bind('w', {'cache_id': 'local-test'})
        self.speech = Path('README.md').read_text().splitlines()[2]
        await self.context('recording')

    async def asyncTearDown(self):
        await self.service.shutdown(); self.store.close(); self.tmp.cleanup()

    async def wait(self, predicate):
        for _ in range(300):
            if predicate(): return
            await asyncio.sleep(.005)
        self.fail('condition not reached')

    def row(self): return self.service._conversation('w')

    async def context(self, state, revision=1):
        await self.service.cmd_context('w', {'meeting_state': state, 'segments': [
            {'id': 'readme', 'text': self.speech, 'final': True, 'revision': revision}]})

    async def listen(self):
        await self.service.cmd_proactive('w', {'enabled': True})
        await self.wait(lambda: self.row()['turn_id'] is not None)
        return self.row()

    async def event(self, method, item=None, status='completed', turn=None):
        row = self.row()
        await self.fake.events[row['thread_id']].put({'method': method, 'params': {
            'threadId': row['thread_id'], 'turnId': turn or row['turn_id'],
            'turn': {'id': turn or row['turn_id'], 'status': status}, 'item': item or {}}})

    async def tool(self, name, args, call='call'):
        row = self.row()
        return await self.service._on_server_request('item/tool/call', {'threadId': row['thread_id'],
            'turnId': row['turn_id'], 'callId': call, 'tool': name, 'arguments': args})

    async def test_all_threads_ephemeral_and_read_only_transport(self):
        await self.listen()
        self.assertTrue(all(o['ephemeral'] and o['sandbox']=='read-only' and o['approval_policy']=='never' for o in self.fake.thread_options))
        runtime=CodexRuntime(); runtime.request=AsyncMock(return_value={'thread':{'id':'t'}})
        await runtime.start_thread('/tmp', ephemeral=False)
        self.assertTrue(runtime.request.await_args.args[1]['ephemeral'])
        await runtime.steer('t','turn','hello')
        self.assertEqual(runtime.request.await_args.args, ('turn/steer', {'threadId':'t','expectedTurnId':'turn','input':[{'type':'text','text':'hello'}]}))

    async def test_one_workspace_one_thread_concurrent_sends_ignore_new_task(self):
        await asyncio.gather(*(self.service.cmd_send('w', {'text': self.speech, 'new_task': True}) for _ in range(3)))
        await self.wait(lambda: bool(self.row()['turn_id']))
        self.assertEqual(len(self.fake.threads),1)
        self.assertEqual(len([r for r in self.store.tasks('w') if r['kind']=='chat']),1)
        self.assertEqual(len([r for r in self.store.messages('w') if r['role']=='user']),3)

    async def test_on_off_interrupts_and_no_renewal(self):
        await self.listen(); self.assertTrue((await self.service.cmd_snapshot('w',{}))['listening'])
        await self.service.cmd_proactive('w', {'enabled': False})
        await self.wait(lambda: not self.service.task_workers)
        self.fake.interrupt.assert_awaited_once()
        self.assertFalse((await self.service.cmd_snapshot('w',{}))['listening'])
        self.assertEqual(len(self.fake.requests),1)

    async def test_user_message_steers_same_turn_and_final_visible(self):
        row=await self.listen()
        result=await self.service.cmd_send('w', {'text': self.speech})
        self.assertTrue(result['steered']); self.fake.steer.assert_awaited_once_with(row['thread_id'],row['turn_id'],self.speech)
        await self.context('paused')
        await self.event('item/completed', {'id':'answer','type':'agentMessage','phase':'final_answer','text':self.speech})
        await self.event('turn/completed'); await self.wait(lambda:not self.service.task_workers)
        self.assertEqual([r['text'] for r in self.store.messages('w') if r['role']=='assistant'],[self.speech])
        self.assertEqual(len(self.fake.threads),1)

    async def test_failed_steer_interrupt_answer_and_continue(self):
        row=await self.listen(); old_turn=row['turn_id']
        self.fake.steer.side_effect=RuntimeErrorCode('rpc_error_-32601')
        result=await self.service.cmd_send('w', {'text': self.speech})
        self.assertFalse(result['steered'])
        await self.wait(lambda:self.row()['turn_id'] not in (None,old_turn))
        user_turn=self.row()['turn_id']; self.assertEqual(self.service.turn_modes[row['id']],'user')
        await self.event('item/completed', {'id':'reply','type':'agentMessage','phase':'final_answer','text':'已读'})
        await self.event('turn/completed')
        await self.wait(lambda:self.row()['turn_id'] not in (None,user_turn))
        self.assertEqual(self.service.turn_modes[row['id']],'listen')
        self.assertEqual(len(self.fake.threads),1); self.fake.interrupt.assert_awaited_once()

    async def test_say_only_and_no_intermediate_storage(self):
        await self.listen()
        await self.event('item/agentMessage/delta', {'text':'过程'})
        await self.event('item/completed', {'id':'process','type':'agentMessage','phase':'commentary','text':'过程'})
        await self.tool('say', {'text':self.speech})
        await self.tool('say', {'text':self.speech})  # duplicate request is idempotent
        await self.context('ended')
        await self.event('item/completed', {'id':'end','type':'agentMessage','phase':'final_answer','text':'旁听结束'})
        await self.event('turn/completed'); await self.wait(lambda:not self.service.task_workers)
        messages=(await self.service.cmd_snapshot('w',{}))['messages']
        self.assertEqual([r['text'] for r in messages],[self.speech])
        self.assertEqual(messages[0]['origin'],'say')

    async def test_pause_and_end_wake_wait_and_prevent_renewal(self):
        for state in ('paused','ended'):
            await self.context('recording'); row=await self.listen()
            waiting=asyncio.create_task(self.tool('meeting_wait',{'after_revision':self.service.revisions['w'],'max_wait_seconds':60}))
            await asyncio.sleep(.01); self.assertFalse(waiting.done())
            await self.context(state); result=await asyncio.wait_for(waiting,.2)
            self.assertTrue(json.loads(result['contentItems'][0]['text'])['paused'])
            await self.event('turn/completed'); await self.wait(lambda:not self.service.task_workers)
            self.assertEqual(self.row()['status'],'completed')

    async def test_wait_batches_new_revision_and_reads_latest(self):
        await self.listen(); current=self.service.revisions['w']
        waiting=asyncio.create_task(self.tool('meeting_wait',{'after_revision':current,'max_wait_seconds':1}))
        await asyncio.sleep(.005); await self.context('recording',2)
        await asyncio.sleep(.005); self.assertFalse(waiting.done())
        await self.context('recording',3)
        result=json.loads((await waiting)['contentItems'][0]['text'])
        self.assertEqual(result['revision'],current+2)
        self.assertEqual(result['segments'][0]['revision'],3)
        self.assertFalse((await self.tool('meeting_wait',{'after_revision':999,'max_wait_seconds':0}))['success'])
        self.assertTrue((await self.tool('meeting_read',{'offset':0,'limit':1}))['success'])
        self.assertTrue((await self.tool('meeting_search',{'query':self.speech}))['success'])

    async def test_disconnect_creates_new_thread_with_local_history(self):
        await self.listen(); await self.tool('say',{'text':self.speech})
        self.fake.closed=True
        await self.wait(lambda:not self.service.task_workers)
        self.assertEqual(self.row()['status'],'interrupted')
        replacement=FakeAppServer(); replacement.auto_complete=False
        self.service.runtime_factory=lambda **kw:replacement
        await self.service.cmd_send('w',{'text':'继续'})
        await self.wait(lambda:bool(self.row()['turn_id']))
        prompt=replacement.requests[0][1]['input'][0]['text']
        self.assertIn(self.speech,prompt); self.assertIn('本场已有对话',prompt)
        self.assertTrue(replacement.thread_options[0]['ephemeral'])
        self.assertFalse(replacement.resumed_threads)

    async def test_restart_preserves_history_and_reports_interrupted(self):
        await self.listen(); await self.tool('say',{'text':self.speech})
        await self.service.shutdown()
        replacement=FakeAppServer(); replacement.auto_complete=False
        self.service=AssistantRuntime(self.store,Path.cwd(),runtime_factory=lambda **kw:replacement)
        await self.service.bind('w',{})
        self.assertEqual(self.row()['status'],'interrupted')
        await self.service.cmd_send('w',{'text':'继续'})
        await self.wait(lambda:bool(self.row()['turn_id']))
        self.assertIn(self.speech,replacement.requests[0][1]['input'][0]['text'])

    async def test_read_only_requests_declined_and_stale_tool_rejected(self):
        await self.listen()
        self.assertEqual(await self.service._on_server_request('item/commandExecution/requestApproval',{}),{'decision':'decline'})
        row=self.row()
        result=await self.service._on_server_request('item/tool/call', {'threadId':row['thread_id'],'turnId':'old','tool':'say','arguments':{'text':'stale'}})
        self.assertFalse(result['success']); self.assertFalse(self.store.messages('w'))

    def test_retired_code_absent(self):
        for path in ('assistant_runtime.py','codex_runtime.py','native/MeetingAgentPanel.swift','scripts/replay_meeting_assistant.py'):
            source=Path(path).read_text()
            for name in ('colleague','COLLEAGUE_SCHEMA','assistant_job_','AUTOMATIC_TASK_GUIDANCE','MAX_LIVE_TASKS','thread/resume'):
                self.assertNotIn(name,source,path)

    async def test_confirmed_missing_thread_rebuilds_once_and_answers(self):
        self.fake.auto_complete=True
        await self.service.cmd_send('w',{'text':self.speech})
        await self.wait(lambda:not self.service.task_workers)
        old=self.row()['thread_id']; original=self.fake.start_turn
        async def missing(thread,text,**kw):
            if thread == old: raise RuntimeErrorCode('thread_not_found')
            return await original(thread,text,**kw)
        self.fake.start_turn=missing
        await self.service.cmd_send('w',{'text':'继续回答'})
        await self.wait(lambda:not self.service.task_workers)
        self.assertEqual(self.row()['status'],'completed')
        self.assertNotEqual(self.row()['thread_id'],old)
        self.assertIn(self.speech,self.fake.requests[-1][1]['input'][0]['text'])
        self.assertEqual(len(self.fake.threads),2)

    async def test_final_waits_for_steer_ack_and_fallback_discards_old_final(self):
        await self.listen(); gate=asyncio.Event(); entered=asyncio.Event()
        async def steer(*args):
            entered.set(); await gate.wait(); raise RuntimeErrorCode('unsupported')
        self.fake.steer.side_effect=steer
        sending=asyncio.create_task(self.service.cmd_send('w',{'text':self.speech}))
        await entered.wait()
        await self.event('item/completed',{'id':'old-final','type':'agentMessage','phase':'final_answer','text':'旧旁听结束语'})
        await self.event('turn/completed'); await asyncio.sleep(.01)
        self.assertFalse(any(m['role']=='assistant' for m in self.store.messages('w')))
        gate.set(); await sending
        await self.wait(lambda:self.service.turn_modes.get(self.row()['id'])=='user')
        self.assertFalse(any(m['role']=='assistant' for m in self.store.messages('w')))

    async def test_unknown_interrupt_does_not_start_overlapping_turn(self):
        row=await self.listen(); self.fake.steer.side_effect=RuntimeError('unsupported')
        self.fake.interrupt.side_effect=RuntimeErrorCode('rpc_outcome_unknown')
        await self.service.cmd_send('w',{'text':self.speech})
        self.assertEqual(self.row()['status'],'cancelling')
        self.assertEqual(self.row()['turn_id'],row['turn_id'])
        self.assertEqual(len(self.fake.requests),1)

    async def test_off_during_start_cancels_without_new_listening_turn(self):
        original=self.fake.start_thread; entered=asyncio.Event(); release=asyncio.Event()
        async def start(*args,**kwargs):
            entered.set(); await release.wait(); return await original(*args,**kwargs)
        self.fake.start_thread=start
        await self.service.cmd_proactive('w',{'enabled':True}); await entered.wait()
        await self.service.cmd_proactive('w',{'enabled':False}); release.set()
        await self.wait(lambda:not self.service.task_workers)
        self.assertEqual(self.fake.requests,[])

    async def test_user_input_wakes_real_wait_without_waiting_for_timeout(self):
        await self.listen()
        waiting=asyncio.create_task(self.tool('meeting_wait',{'after_revision':self.service.revisions['w'],'max_wait_seconds':3600}))
        await asyncio.sleep(.01); self.assertFalse(waiting.done())
        await self.service.cmd_send('w',{'text':self.speech})
        self.assertTrue((await asyncio.wait_for(waiting,.2))['success'])

    async def test_legacy_chat_rows_merge_atomically_without_losing_messages(self):
        with tempfile.TemporaryDirectory() as directory:
            old=AssistantStore(directory)
            old.db.execute("INSERT INTO workspace(id,updated) VALUES('old',0)")
            old.db.execute('DROP INDEX one_assistant_conversation')
            for i,status in enumerate(('completed','running')):
                old.db.execute("INSERT INTO task(id,workspace_id,title,origin,status,created,updated,kind) VALUES(?, 'old','助理','user',?,?,0,'chat')",(str(i),status,i))
                old.db.execute("INSERT INTO message VALUES(?,?,'user',?,'completed','user',?,0)",(str(i),str(i),self.speech,i))
            old.close()
            reopened=AssistantStore(directory)
            try:
                self.assertEqual(len(reopened.tasks('old')),1)
                self.assertEqual(len(reopened.messages('old')),2)
                self.assertEqual(reopened.tasks('old')[0]['status'],'interrupted')
                self.assertEqual([r['text'] for r in reopened.messages('old')],[self.speech]*2)
            finally: reopened.close()

    async def test_completed_user_answer_survives_late_listener_interrupt(self):
        await self.listen()
        await self.service.cmd_send('w',{'text':self.speech})
        async def already_completed(thread,turn):
            await self.event('item/completed',{'id':'finished','type':'agentMessage','phase':'final_answer','text':self.speech})
            await self.event('turn/completed',status='completed')
        self.fake.interrupt.side_effect=already_completed
        await self.service.cmd_proactive('w',{'enabled':False})
        await self.wait(lambda:not self.service.task_workers)
        self.assertEqual([m['text'] for m in self.store.messages('w') if m['role']=='assistant'],[self.speech])
