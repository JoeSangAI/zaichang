"""P8 lifecycle tests: real project text, in-process transport, no model or live writes."""
import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from unittest.mock import AsyncMock

from assistant_runtime import AssistantRuntime, AssistantStore
from codex_runtime import CodexRuntime, RuntimeErrorCode
from tests.test_assistant_runtime import FakeAppServer


def public_image(name):
    root = Path(__file__).resolve().parents[1]
    assets = root / "public/docs/assets"
    if not assets.is_dir():
        assets = root / "docs/assets"
    return (assets / name).resolve()


class ListenerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = AssistantStore(self.tmp.name)
        self.fake = FakeAppServer(); self.fake.auto_complete = False
        self.fake.steer = AsyncMock(return_value={})
        self.fake.interrupt = AsyncMock(wraps=self.fake.interrupt)
        self.service = AssistantRuntime(self.store, Path.cwd(), output_root=Path(self.tmp.name) / "outputs", runtime_factory=lambda **kw: self.fake)
        self.service._schedule_overview = lambda *a, **kw: None
        self.service.wait_batch_seconds = .03
        await self.service.bind('w', {'cache_id': 'local-test'})
        self.speech = Path('README.md').read_text().splitlines()[2]
        await self.context('recording')

    async def asyncTearDown(self):
        await self.service.shutdown(); self.store.close(); self.tmp.cleanup()

    async def wait(self, predicate, seconds=1.5):
        for _ in range(int(seconds / .005)):
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

    def req(self):
        """Latest user request; each runs on its own thread."""
        return [r for r in self.store.tasks('w') if r['kind'] == 'work' and r['lane'] == 'request'][-1]

    async def ask(self, text):
        await self.service.cmd_send('w', {'text': text})
        await self.wait(lambda: bool(self.req()['turn_id']))
        return self.req()

    async def event(self, method, item=None, status='completed', turn=None, row=None):
        row = self.store.task(row['id']) if row else self.row()
        await self.fake.events[row['thread_id']].put({'method': method, 'params': {
            'threadId': row['thread_id'], 'turnId': turn or row['turn_id'],
            'turn': {'id': turn or row['turn_id'], 'status': status}, 'item': item or {}}})

    async def tool(self, name, args, call='call'):
        row = self.row()
        return await self.service._on_server_request('item/tool/call', {'threadId': row['thread_id'],
            'turnId': row['turn_id'], 'callId': call, 'tool': name, 'arguments': args})

    async def answer(self, row, text):
        await self.event('item/completed', {'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer', 'text': text}, row=row)
        await self.event('turn/completed', row=row)
        await self.wait(lambda: self.store.task(row['id'])['status'] == 'completed')

    async def test_all_threads_ephemeral_and_read_only_transport(self):
        await self.listen()
        self.assertTrue(all(o['ephemeral'] and o['sandbox']=='read-only' and o['approval_policy']=='never' for o in self.fake.thread_options))
        runtime=CodexRuntime(); runtime.request=AsyncMock(return_value={'thread':{'id':'t'}})
        await runtime.start_thread('/tmp', ephemeral=False)
        self.assertTrue(runtime.request.await_args.args[1]['ephemeral'])
        await runtime.steer('t','turn','hello')
        self.assertEqual(runtime.request.await_args.args, ('turn/steer', {'threadId':'t','expectedTurnId':'turn','input':[{'type':'text','text':'hello'}]}))

    async def test_concurrent_sends_each_run_at_once_on_their_own_thread(self):
        # A slow image must not hold up the next question (2026-10-29 meeting).
        await self.listen()
        await asyncio.gather(*(self.service.cmd_send('w', {'text': f'{self.speech}{i}'}) for i in range(3)))
        requests = lambda: [r for r in self.store.tasks('w') if r['lane'] == 'request']
        await self.wait(lambda: len(requests()) == 3 and all(r['turn_id'] for r in requests()))
        self.assertEqual(len({r['thread_id'] for r in requests()} | {self.row()['thread_id']}), 4)
        self.assertEqual(len([r for r in self.store.tasks('w') if r['kind']=='chat']),1)
        self.assertEqual((self.row()['status'], self.service.turn_modes[self.row()['id']]), ('running', 'listen'))
        self.fake.interrupt.assert_not_awaited()
        state = await self.service.cmd_snapshot('w', {})
        self.assertEqual(state['activity'], '正在思考…（共 3 项在做）')
        self.assertEqual(state['work'], [])
        # The last request answers first; the others keep going.
        await self.answer(requests()[-1], '先答完的')
        self.assertTrue((await self.service.cmd_snapshot('w', {}))['awaiting_response'])
        prompt = [p for m, p in self.fake.requests if m == 'turn/start' and p['threadId'] == requests()[-1]['thread_id']][0]
        self.assertIn('其他线程正在处理的用户请求', prompt['input'][0]['text'])

    async def test_on_off_interrupts_and_no_renewal(self):
        await self.listen(); self.assertTrue((await self.service.cmd_snapshot('w',{}))['listening'])
        await self.service.cmd_proactive('w', {'enabled': False})
        await self.wait(lambda: not self.service.task_workers)
        self.fake.interrupt.assert_awaited_once()
        self.assertFalse((await self.service.cmd_snapshot('w',{}))['listening'])
        self.assertEqual(len(self.fake.requests),1)

    async def test_user_activity_visible_through_tools_and_cleared_on_completion(self):
        row = await self.ask('我们之前投放的素材有吗')
        state = await self.service.cmd_snapshot('w', {})
        self.assertTrue(state['awaiting_response'])
        self.assertFalse(state['listening'])
        self.assertEqual((state['activity'], state['conversation_status']), ('正在思考…', 'running'))
        await self.event('item/started', {'id': 'search', 'type': 'webSearch'}, row=row)
        await self.wait(lambda: self.service.activities.get(row['id']) == '正在查资料…')
        await self.event('item/completed', {'id': 'search', 'type': 'webSearch'}, row=row)
        await self.wait(lambda: self.service.activities.get(row['id']) == '正在思考…')
        await self.answer(row, self.speech)
        await self.wait(lambda: not self.service.task_workers)
        state = await self.service.cmd_snapshot('w', {})
        self.assertFalse(state['awaiting_response'])
        self.assertEqual(state['activity'], '')
        self.assertEqual([m['text'] for m in state['messages'] if m['role'] == 'assistant'], [self.speech])

    async def test_question_beside_listening_and_cancel_keeps_listening(self):
        listener = await self.listen()
        self.assertFalse((await self.service.cmd_snapshot('w', {}))['awaiting_response'])
        row = await self.ask('我们之前投放的素材有吗')
        state = await self.service.cmd_snapshot('w', {})
        self.assertTrue(state['awaiting_response'])
        self.assertTrue(state['listening'])
        await self.service.cmd_cancel('w', {})
        self.fake.interrupt.assert_awaited_once_with(row['thread_id'], row['turn_id'])
        await self.event('turn/completed', status='interrupted', row=row)
        await self.wait(lambda: self.store.task(row['id'])['status'] == 'completed')
        state = await self.service.cmd_snapshot('w', {})
        self.assertFalse(state['awaiting_response'])
        self.assertTrue(self.store.workspace('w')['proactive'])
        self.assertEqual(self.row()['turn_id'], listener['turn_id'])

    async def test_image_generation_asset_survives_final_text_and_reopen(self):
        image = public_image('app-icon.png')
        self.assertTrue(image.is_file())
        row = await self.ask('把图片显示出来')
        await self.event('item/completed', {'id': 'image', 'type': 'imageGeneration', 'savedPath': str(image), 'status': 'completed'}, row=row)
        await self.event('item/completed', {'id': 'missing', 'type': 'imageGeneration', 'savedPath': str(image.parent / 'missing.png'), 'status': 'completed'}, row=row)
        await self.answer(row, self.speech)
        await self.wait(lambda: not self.service.task_workers)
        messages = (await self.service.cmd_snapshot('w', {}))['messages']
        self.assertEqual(len([m for m in messages if m['role'] == 'assistant']), 2)
        saved = next((self.store.directory / 'artifacts').iterdir())
        self.assertEqual(saved.read_bytes(), image.read_bytes())
        self.assertEqual(messages[-2]['text'], f'[生成的图片]({saved.as_uri()})')
        reopened = AssistantStore(self.tmp.name)
        try:
            self.assertEqual(reopened.messages('w')[-2]['text'], messages[-2]['text'])
        finally:
            reopened.close()

    async def test_only_final_selected_images_visible_during_generation_and_after_reopen(self):
        images = [public_image(name) for name in
                  ('app-icon.png', 'meeting-assistant-v030.png')]
        row = await self.ask('给用户更加简洁，只交付最终产出的图片')
        for index, image in enumerate([*images, images[-1]]):
            self.assertTrue(image.is_file())
            await self.event('item/completed', {'id':str(index),'type':'imageGeneration','savedPath':str(image),'status':'completed'}, row=row)
        await self.wait(lambda: len([m for m in self.store.messages('w') if ':image:' in m['id']]) == 3)
        self.assertFalse([m for m in (await self.service.cmd_snapshot('w', {}))['messages'] if m['role']=='assistant'])
        final = '\n'.join(f'[最终图片 {i+1}](<{p}>)' for i,p in enumerate(images))
        await self.answer(row, final)
        await self.wait(lambda: not self.service.task_workers)
        self.assertEqual([m['text'] for m in (await self.service.cmd_snapshot('w', {}))['messages'] if m['role']=='assistant'], [final])
        reopened = AssistantStore(self.tmp.name)
        try:
            self.assertEqual(len([m for m in reopened.messages('w') if ':image:' in m['id']]), 3)
            visible = self.service._delivery_messages(reopened.messages('w'))
            self.assertEqual([m['text'] for m in visible if m['role']=='assistant'], [final])
        finally:
            reopened.close()

    async def test_user_message_executes_on_own_thread_while_listening_continues(self):
        listener=await self.listen()
        row=await self.ask(self.speech)
        self.fake.steer.assert_not_awaited(); self.fake.interrupt.assert_not_awaited()
        self.assertNotEqual(row['thread_id'], listener['thread_id'])
        self.assertEqual(self.row()['turn_id'], listener['turn_id'])
        start=[p for m,p in self.fake.requests if m=='turn/start' and p['threadId']==row['thread_id']][0]
        self.assertIn('execution_directory', start)
        self.assertIn('用户刚在侧栏说', start['input'][0]['text'])
        options=self.fake.threads[row['thread_id']]
        self.assertIn('这个线程只负责把它答好', options['developer_instructions'])
        await self.context('paused')
        await self.answer(row, self.speech)
        # A reply sits under the user's message, without a task heading.
        self.assertEqual([r['text'] for r in self.store.messages('w') if r['role']=='assistant'],[self.speech])
        self.assertNotIn('execution_directory', [p for m,p in self.fake.requests if p.get('threadId')==listener['thread_id']][-1])

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

    # Batching asserts on length; keep the words independent of README edits.
    WORDS = '我们先确认本周要验证的三件事：模拟人物的数据来源、真人对照的样本，以及哪一个品牌问题最适合作为第一个实验，下周一前把方案发给大家看。'

    async def speak(self, text, revision=1):
        await self.service.cmd_context('w', {'meeting_state': 'recording', 'segments': [
            {'id': 'readme', 'text': self.speech, 'final': True, 'revision': 1},
            {'id': 'next', 'text': text, 'final': True, 'revision': revision, 'start': 65, 'speaker': '主持人'}]})

    async def test_wait_batches_new_revision_and_reads_latest(self):
        await self.listen(); current=self.service.revisions['w']
        waiting=asyncio.create_task(self.tool('meeting_wait',{'after_revision':current,'max_wait_seconds':1}))
        await asyncio.sleep(.005); await self.speak(self.WORDS[:40])
        await asyncio.sleep(.005); self.assertFalse(waiting.done())
        await self.speak(self.WORDS)
        result=json.loads((await waiting)['contentItems'][0]['text'])
        self.assertEqual(result['revision'],current+2)
        self.assertEqual(result['speech'],['1:05 主持人：'+self.WORDS])
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
        await self.ask('继续')
        prompt=replacement.requests[0][1]['input'][0]['text']
        self.assertIn(self.speech,prompt); self.assertIn('本场已有对话',prompt)
        self.assertTrue(replacement.thread_options[0]['ephemeral'])
        self.assertFalse(replacement.resumed_threads)

    async def test_restart_preserves_history_and_reports_interrupted(self):
        await self.listen(); await self.tool('say',{'text':self.speech})
        await self.service.shutdown()
        replacement=FakeAppServer(); replacement.auto_complete=False
        self.service=AssistantRuntime(self.store,Path.cwd(),output_root=Path(self.tmp.name) / "outputs", runtime_factory=lambda **kw:replacement)
        await self.service.bind('w',{})
        self.assertEqual(self.row()['status'],'interrupted')
        await self.ask('继续')
        self.assertIn(self.speech,replacement.requests[0][1]['input'][0]['text'])

    async def test_read_only_requests_declined_and_stale_tool_rejected(self):
        await self.listen()
        self.assertEqual(await self.service._on_server_request('item/commandExecution/requestApproval',{}),{'decision':'decline'})
        row=self.row()
        live={'threadId':row['thread_id'],'turnId':row['turn_id']}
        self.assertEqual(await self.service._on_server_request('item/commandExecution/requestApproval',live),{'decision':'decline'})
        self.assertEqual(await self.service._on_server_request('item/permissions/requestApproval',live),{'permissions':{},'scope':'turn'})
        self.assertEqual(await self.service._on_server_request('mcpServer/elicitation/request',live),{'action':'decline'})
        self.assertFalse(self.service.pending_requests)
        result=await self.service._on_server_request('item/tool/call', {'threadId':row['thread_id'],'turnId':'old','tool':'say','arguments':{'text':'stale'}})
        self.assertFalse(result['success']); self.assertFalse(self.store.messages('w'))

    def test_retired_code_absent(self):
        for path in ('assistant_runtime.py','codex_runtime.py','native/MeetingAgentPanel.swift','scripts/replay_meeting_assistant.py'):
            source=Path(path).read_text()
            for name in ('colleague','COLLEAGUE_SCHEMA','assistant_job_','AUTOMATIC_TASK_GUIDANCE','MAX_LIVE_TASKS','thread/resume'):
                self.assertNotIn(name,source,path)

    async def test_confirmed_missing_listening_thread_rebuilds_once(self):
        old=(await self.listen())['thread_id']; original=self.fake.start_turn
        async def missing(thread,text,**kw):
            if thread == old: raise RuntimeErrorCode('thread_not_found')
            return await original(thread,text,**kw)
        self.fake.start_turn=missing
        await self.event('turn/completed')
        await self.wait(lambda:self.row()['thread_id'] not in (None,old) and bool(self.row()['turn_id']))
        self.assertEqual((self.row()['status'], self.service.turn_modes[self.row()['id']]), ('running', 'listen'))
        self.assertIn(self.speech,self.fake.requests[-1][1]['input'][0]['text'])
        self.assertEqual(len(self.fake.threads),2)

    async def test_silent_request_is_stopped_and_frees_the_assistant(self):
        # 2026-10-29: an image turn went silent after its image and never ended.
        with mock.patch('assistant_runtime.TURN_STALL_SECONDS', 0.3):
            row = await self.ask('再生成一张')
            await self.wait(lambda: self.store.task(row['id'])['status'] == 'failed', seconds=4)
        self.fake.interrupt.assert_awaited_once_with(row['thread_id'], row['turn_id'])
        state = await self.service.cmd_snapshot('w', {})
        self.assertFalse(state['awaiting_response'])
        self.assertIn('长时间没有进展', [m['text'] for m in state['messages'] if m['role'] == 'assistant'][-1])

    async def test_silent_listening_turn_restarts_instead_of_ending(self):
        with mock.patch('assistant_runtime.TURN_STALL_SECONDS', 0.3):
            first = await self.listen()
            await self.wait(lambda: self.row()['turn_id'] not in (None, first['turn_id']), seconds=4)
        self.assertEqual(self.service.turn_modes[self.row()['id']], 'listen')
        self.assertNotEqual(self.row()['thread_id'], first['thread_id'])

    async def test_waiting_on_our_own_tool_is_not_a_stall(self):
        with mock.patch('assistant_runtime.TURN_STALL_SECONDS', 0.2):
            await self.listen()
            waiting = asyncio.create_task(self.tool('meeting_wait', {'after_revision': self.service.revisions['w'], 'max_wait_seconds': 2}))
            await asyncio.sleep(1.6)
            self.assertFalse(waiting.done())
            self.assertEqual(self.row()['status'], 'running')
            self.fake.interrupt.assert_not_awaited()
            await self.context('paused'); await waiting

    async def test_off_during_start_cancels_without_new_listening_turn(self):
        original=self.fake.start_thread; entered=asyncio.Event(); release=asyncio.Event()
        async def start(*args,**kwargs):
            entered.set(); await release.wait(); return await original(*args,**kwargs)
        self.fake.start_thread=start
        await self.service.cmd_proactive('w',{'enabled':True}); await entered.wait()
        await self.service.cmd_proactive('w',{'enabled':False}); release.set()
        await self.wait(lambda:not self.service.task_workers)
        self.assertEqual(self.fake.requests,[])

    async def test_answered_request_wakes_listening_without_waiting_for_timeout(self):
        await self.listen()
        waiting=asyncio.create_task(self.tool('meeting_wait',{'after_revision':self.service.revisions['w'],'max_wait_seconds':3600}))
        row=await self.ask(self.speech)
        await asyncio.sleep(.01); self.assertFalse(waiting.done())  # another thread answers it
        await self.answer(row, '已回答')
        result=json.loads((await asyncio.wait_for(waiting,.2))['contentItems'][0]['text'])
        self.assertEqual((result['background'][0]['origin'], result['background'][0]['result']), ('user', '已回答'))

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

    async def test_disabling_listener_does_not_cancel_user_execution(self):
        await self.listen()
        row=await self.ask(self.speech)
        await self.service.cmd_proactive('w',{'enabled':False})
        self.assertEqual(self.store.task(row['id'])['turn_id'],row['turn_id'])
        self.assertEqual(self.store.task(row['id'])['status'],'running')
        await self.event('turn/completed',status='interrupted')  # the listener's own turn ends
        await self.answer(row, self.speech)
        await self.wait(lambda:not self.service.task_workers)
        self.assertEqual([m['text'] for m in self.store.messages('w') if m['role']=='assistant'],[self.speech])

    async def request_approval(self, method='item/commandExecution/requestApproval', **extra):
        row=await self.ask('我主动交办时要能完整执行')
        request=asyncio.create_task(self.service._on_server_request(method, {
            'threadId': row['thread_id'], 'turnId': row['turn_id'], 'itemId': 'approval',
            'reason': '保存用户要求的作品', **extra}))
        await self.wait(lambda: bool(self.service.pending_requests))
        return request, next(iter(self.service.pending_requests))

    async def test_approval_is_visible_scoped_and_granted_once(self):
        request, request_id = await self.request_approval(command='保存用户要求的作品')
        state=await self.service.cmd_snapshot('w',{})
        self.assertEqual(state['requests'][0]['kind'],'approval')
        self.assertFalse(request.done())
        with self.assertRaisesRegex(ValueError,'approval_not_found'):
            await self.service.cmd_respond('other',{'request_id':request_id,'accepted':True})
        await self.service.cmd_respond('w',{'request_id':request_id,'accepted':True})
        self.assertEqual(await request,{'decision':'accept'})
        self.assertFalse((await self.service.cmd_snapshot('w',{}))['requests'])
        with self.assertRaisesRegex(ValueError,'approval_not_found'):
            await self.service.cmd_respond('w',{'request_id':request_id,'accepted':True})

    async def test_cancel_dismisses_approval_without_granting(self):
        request, _ = await self.request_approval()
        await self.service.cmd_cancel('w',{})
        self.assertEqual(await request,{'decision':'decline'})
        await self.wait(lambda:not self.service.task_workers)
        self.assertFalse(self.service.pending_requests)

    async def test_user_question_answers_and_permission_grants_are_turn_scoped(self):
        request, request_id = await self.request_approval('item/tool/requestUserInput',questions=[
            {'id':'image','question':'已有海报和新生成图片是否都需要？','header':'图片'}])
        await self.service.cmd_respond('w',{'request_id':request_id,'accepted':True,'answers':{'image':'对，两种都要'}})
        self.assertEqual(await request,{'answers':{'image':{'answers':['对，两种都要']}}})
        row=self.req()
        permissions={'fileSystem':{'write':[str(self.service.output_root)]}}
        request=asyncio.create_task(self.service._on_server_request('item/permissions/requestApproval',{
            'threadId':row['thread_id'],'turnId':row['turn_id'],'permissions':permissions}))
        await self.wait(lambda:bool(self.service.pending_requests))
        await self.service.cmd_respond('w',{'request_id':next(iter(self.service.pending_requests)),'accepted':True})
        self.assertEqual(await request,{'permissions':permissions,'scope':'turn'})

    async def test_mcp_form_requires_explicit_response_and_validates_types(self):
        request, request_id = await self.request_approval('mcpServer/elicitation/request', mode='form',
            message='确认作品保存选项', requestedSchema={'type':'object','required':['save'],
                'properties':{'save':{'type':'boolean','title':'保存图片'},'detail':{'type':'string','title':'补充说明'}}})
        display = self.service.pending_requests[request_id]['display']
        self.assertEqual([q['required'] for q in display['questions']], [True, False])
        self.assertFalse(request.done())
        with self.assertRaisesRegex(ValueError,'请检查表单'):
            await self.service.cmd_respond('w',{'request_id':request_id,'accepted':True,'answers':{'save':'perhaps'}})
        self.assertFalse(request.done())
        await self.service.cmd_respond('w',{'request_id':request_id,'accepted':True,'answers':{'save':'true'}})
        self.assertEqual(await request,{'action':'accept','content':{'save':True}})

    async def test_user_execution_has_full_access_and_listener_work_is_bounded(self):
        await self.ask('我主动交办时要能完整执行')
        self.assertTrue(self.fake.requests[-1][1]['full_access'])
        await self.service.cmd_cancel('w', {})
        await self.wait(lambda: not self.service.task_workers)
        await self.start_work()
        start = [p for m, p in self.fake.requests if m == 'turn/start' and p['threadId'] == self.work()['thread_id']][-1]
        self.assertFalse(start['full_access'])

    async def test_listener_work_never_waits_for_an_answer_mid_meeting(self):
        await self.start_work()
        work = self.work()
        answer = await self.service._on_server_request('item/tool/requestUserInput', {
            'threadId': work['thread_id'], 'turnId': work['turn_id'], 'questions': [{'id': 'q', 'question': '要哪种？'}]})
        self.assertEqual(answer, {'answers': {}})
        self.assertFalse(self.service.pending_requests)

    async def test_user_question_mid_meeting_continues_after_limit(self):
        with mock.patch('assistant_runtime.MEETING_REQUEST_SECONDS', 0.2):
            request, request_id = await self.request_approval('item/tool/requestUserInput',
                questions=[{'id': 'q', 'question': '要哪种？'}])
            self.assertIn('秒内未回复', self.service.pending_requests[request_id]['display']['detail'])
            self.assertEqual(await asyncio.wait_for(request, 3), {'answers': {}})
        self.assertFalse(self.service.pending_requests)

    def work(self):
        return next(r for r in self.store.tasks('w') if r['kind'] == 'work' and r['lane'] != 'request')

    async def work_event(self, method, item=None):
        row = self.work()
        await self.fake.events[row['thread_id']].put({'method': method, 'params': {
            'threadId': row['thread_id'], 'turnId': row['turn_id'],
            'turn': {'id': row['turn_id'], 'status': 'completed'}, 'item': item or {}}})

    async def start_work(self):
        await self.listen()
        result = await self.tool('start_task', {'title': '查 Qoder 校园推广', 'goal': self.speech})
        self.assertTrue(result['success'], result)
        await self.wait(lambda: self.work()['turn_id'] is not None)
        return json.loads(result['contentItems'][0]['text'])

    def test_listener_prompt_lets_listening_speak(self):
        prompt = AssistantRuntime._listener_prompt()
        self.assertNotIn('不发消息', prompt); self.assertNotIn('不需要回应', prompt)
        self.assertIn('say', prompt); self.assertIn('start_task', prompt)

    async def test_start_task_works_beside_listening_and_reports_back(self):
        data = await self.start_work()
        work = self.work()
        self.assertEqual((data['task_id'], work['origin'], work['status']), (work['id'], 'proactive', 'running'))
        # Listening keeps its own turn while the work runs on a separate thread.
        self.assertEqual((self.row()['status'], self.service.turn_modes[self.row()['id']]), ('running', 'listen'))
        self.assertNotEqual(work['thread_id'], self.row()['thread_id'])
        options = self.fake.threads[work['thread_id']]
        self.assertEqual([t['name'] for t in options['dynamic_tools']], ['meeting_read', 'meeting_search'])
        start = [p for m, p in self.fake.requests if m == 'turn/start' and p['threadId'] == work['thread_id']][-1]
        self.assertTrue(start['execution_directory'].startswith(str(Path(self.tmp.name) / 'outputs')))
        self.assertIn(self.speech, start['input'][0]['text'])
        state = await self.service.cmd_snapshot('w', {})
        self.assertEqual([w['title'] for w in state['work']], ['查 Qoder 校园推广'])
        self.assertFalse(state['awaiting_response'])
        await self.work_event('item/completed', {'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer', 'text': self.speech})
        await self.work_event('turn/completed')
        await self.wait(lambda: self.work()['status'] == 'completed')
        state = await self.service.cmd_snapshot('w', {})
        self.assertEqual(state['work'], [])
        reply = [m for m in state['messages'] if m['role'] == 'assistant'][-1]
        self.assertEqual((reply['text'], reply['origin']), (f'**查 Qoder 校园推广**\n\n{self.speech}', 'proactive'))
        background = self.service._with_background('w', {}, 'other-listener')['background']
        self.assertEqual((background[0]['status'], background[0]['result']), ('completed', reply['text']))
        self.assertEqual(self.row()['status'], 'running')

    async def test_work_threads_cannot_speak_or_spawn(self):
        await self.start_work()
        work = self.work()
        for name, args in (('say', {'text': self.speech}), ('start_task', {'title': 'x', 'goal': 'y'}),
                           ('meeting_wait', {'after_revision': 0, 'max_wait_seconds': 0})):
            result = await self.service._on_server_request('item/tool/call', {'threadId': work['thread_id'],
                'turnId': work['turn_id'], 'callId': name, 'tool': name, 'arguments': args})
            self.assertFalse(result['success'], name)
        read = await self.service._on_server_request('item/tool/call', {'threadId': work['thread_id'],
            'turnId': work['turn_id'], 'callId': 'read', 'tool': 'meeting_search', 'arguments': {'query': self.speech[:6]}})
        self.assertTrue(read['success'])

    async def test_cancel_work_keeps_listening_on(self):
        await self.start_work()
        result = await self.service.cmd_cancel_work('w', {})
        self.assertEqual(result, {'cancelled': 1})
        await self.wait(lambda: self.work()['status'] == 'completed')
        self.assertTrue(self.store.workspace('w')['proactive'])
        self.assertEqual((self.row()['status'], self.service.turn_modes[self.row()['id']]), ('running', 'listen'))
        self.assertEqual((await self.service.cmd_snapshot('w', {}))['work'], [])

    async def test_work_concurrency_cap_and_queue_limit(self):
        await self.listen()
        results = [await self.tool('start_task', {'title': f'任务{i}', 'goal': self.speech}, call=f'c{i}') for i in range(7)]
        self.assertEqual([r['success'] for r in results], [True] * 6 + [False])
        statuses = [r['status'] for r in self.store.tasks('w') if r['kind'] == 'work']
        self.assertEqual((statuses.count('running'), statuses.count('queued')), (2, 4))

    async def test_bookkeeping_changes_are_not_resent(self):
        await self.listen(); await self.speak(self.WORDS)
        seen = self.service.revisions['w']
        await self.speak(self.WORDS, revision=7)  # projection batch rewrite only
        self.assertGreater(self.service.revisions['w'], seen)
        self.assertEqual(self.service._meeting_delta('w', seen)['speech'], [])

    async def test_thin_batch_stays_open_until_enough_words(self):
        await self.listen(); current = self.service.revisions['w']
        waiting = asyncio.create_task(self.tool('meeting_wait', {'after_revision': current, 'max_wait_seconds': 1}))
        await asyncio.sleep(.005); await self.speak('嗯对')
        await asyncio.sleep(.1); self.assertFalse(waiting.done())
        await self.speak('嗯对。' + self.WORDS)
        result = json.loads((await asyncio.wait_for(waiting, .5))['contentItems'][0]['text'])
        self.assertEqual(result['speech'], ['1:05 主持人：嗯对。' + self.WORDS])

    async def test_background_rides_along_only_when_changed(self):
        await self.start_work()
        listener = self.row()['id']
        first = self.service._with_background('w', {}, listener)
        self.assertEqual(first['background'][0]['status'], 'running')
        self.assertNotIn('background', self.service._with_background('w', {}, listener))
        await self.work_event('item/completed', {'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer', 'text': self.speech})
        await self.work_event('turn/completed')
        await self.wait(lambda: self.work()['status'] == 'completed')
        self.assertEqual(self.service._with_background('w', {}, listener)['background'][0]['status'], 'completed')
