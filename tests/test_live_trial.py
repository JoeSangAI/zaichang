import unittest
import threading
import time
from unittest.mock import patch, Mock
import io
import contextlib
import live_trial
import tempfile
import json

class RecordingTimeBoundary(unittest.TestCase):
    def test_preparation_and_permission_wait_do_not_become_recording(self):
        from pathlib import Path
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'health.json'
            path.write_text(json.dumps({'phase':'stopped','previous_audio_seconds':0,'previous_wall_seconds':100,'elapsed_seconds':0,'tracks':{}}))
            h=live_trial.HealthWriter('synthetic','com.tencent.meeting',180,123,path=path)
            h.observe({'type':'stopped','reason':'user_stop','received_at':57,'recording_elapsed_seconds':0})
            self.assertEqual(live_trial.prior_totals(path)[1],100)
            h.observe({'type':'stopped','reason':'user_stop','received_at':90,'recording_elapsed_seconds':12.5})
            self.assertEqual(live_trial.prior_totals(path)[1],112.5)
from pathlib import Path
from live_trial import trial_config, TrialView
from tests.test_dual_track import segment


class LiveContract(unittest.TestCase):
    def test_key_then_confirmation_no_capture_on_cancel(self):
        order=[]
        native=Mock();native.exists.return_value=True
        native.__str__=Mock(return_value='mock-native')
        def key(prompt):
            order.append('hidden_key'); return 'synthetic-key'
        def confirm(prompt):
            order.append('explicit_start'); return '取消'
        with patch.object(live_trial,'NATIVE',native), patch.object(live_trial.sys,'argv',['trial','--bundle','selected-app']), \
             patch.object(live_trial,'single_instance',return_value=Mock()), \
             patch.object(live_trial.sys.stdin,'isatty',return_value=True), \
             patch.object(live_trial.subprocess,'run',return_value=Mock(stdout='{"pids":[1]}')), \
             patch.object(live_trial.getpass,'getpass',side_effect=key), \
             patch('builtins.input',side_effect=confirm), patch.object(live_trial.subprocess,'Popen') as launch, \
             contextlib.redirect_stdout(io.StringIO()):
            live_trial.main()
            launch.assert_not_called()
        self.assertEqual(order,['hidden_key','explicit_start'])

    def test_cost_and_duration_limit(self):
        self.assertEqual(trial_config('selected-app', 'synthetic-key')['maxSeconds'], 450)
        for seconds in [0, 451, 481, -1]:
            with self.assertRaises(ValueError): trial_config('selected-app', 'synthetic-key', seconds)
        for key in ['', 'key\ninject']:
            with self.assertRaises(ValueError): trial_config('selected-app', key)

    def test_health_allowlist_no_transcript_or_secret(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'health.json'
            writer=live_trial.HealthWriter('mock','selected-app',450,1,path)
            writer.observe(segment(track='remote',text='private transcript',key='secret-value'))
            writer.observe({'type':'health','elapsed_seconds':1,
                'mic':{'pcm_frames':3,'sent_audio_seconds':1,'key':'secret-value'},
                'remote':{'pcm_frames':0,'nonzero_frames':0,'asr_ready':False,'text':'private transcript'}})
            content=path.read_text()
            self.assertNotIn('secret-value',content)
            self.assertNotIn('private transcript',content)
            self.assertEqual(json.loads(content)['tracks']['remote']['pcm_frames'],0)
            self.assertEqual(path.stat().st_mode & 0o777,0o600)

    def test_cumulative_wall_and_cost_accounting(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'health.json'
            path.write_text(json.dumps({'phase':'stopped','previous_audio_seconds':18.7855,
                'previous_wall_seconds':19,'elapsed_seconds':450,
                'tracks':{'mic':{'sent_audio_seconds':450},'remote':{'sent_audio_seconds':450}}}))
            audio,wall=live_trial.prior_totals(path)
            self.assertEqual(wall,469)
            self.assertAlmostEqual(audio,918.7855)
            self.assertLess(audio*live_trial.RATE,1)

    def test_mock_result_frames_and_stop(self):
        view = TrialView('demo', 'selected-app')
        p = segment(final=False, track='remote', end_time_known=False)
        self.assertIn('暂定', view.receive(p))
        self.assertIn('句末结果', view.receive(segment(2, track='remote', text='修订后')))
        self.assertFalse(view.bridge.snapshot(2)['synthetic'])
        self.assertEqual(len(view.bridge.snapshot(2)['whole_meeting']), 1)
        self.assertIn('已停止', view.receive({'type':'stopped','received_at':3,'reason':'user_stop'}))
        with self.assertRaises(ValueError): view.receive(segment(3, track='mic'))

    def test_slow_terminal_bounded_and_partial_coalesced(self):
        entered=threading.Event(); release=threading.Event()
        def slow(text): entered.set(); release.wait(3)
        pump=live_trial.DisplayPump(slow,capacity=2)
        try:
            pump.push({'type':'started'},'start'); self.assertTrue(entered.wait(1))
            for i in range(10000):
                pump.push({'type':'segment','track':'remote','segment_id':'one','final':False},str(i))
            self.assertEqual(len(pump.pending),1)
            self.assertEqual(pump.pending['remote'][1],'9999')
            pump.push({'type':'segment','track':'mic','segment_id':'two','final':True},'final')
            pump.push({'type':'stopped'},'stopped')
            self.assertEqual(pump.pending,{})
            with self.assertRaisesRegex(ValueError,'terminal_display_backpressure'):
                pump.push({'type':'started'},'overflow')
        finally:
            release.set(); pump.finish()
        self.assertFalse(pump.thread.is_alive())

    def test_gui_stream_is_jsonl_without_terminal_escapes(self):
        rows=[]
        pump=live_trial.GUIEventPump(rows.append)
        pump.push({'type':'segment','track':'remote','segment_id':'s','final':False},json.dumps({'type':'segment','text':'fake partial'}))
        pump.push({'type':'segment','track':'remote','segment_id':'s','final':True},json.dumps({'type':'segment','text':'fake final'}))
        pump.push({'type':'stopped'},json.dumps({'type':'stopped'}))
        pump.finish()
        parsed=[json.loads(line) for block in rows for line in block.splitlines() if line]
        self.assertTrue(any(r.get('text')=='fake final' for r in parsed))
        self.assertEqual(parsed[-1]['type'],'stopped')
        self.assertFalse(any('\x1b' in r for r in rows))

    def test_terminal_failure_visible(self):
        def failed(text): raise BrokenPipeError()
        pump=live_trial.DisplayPump(failed)
        pump.push({'type':'started'},'start')
        pump.thread.join(1)
        with self.assertRaisesRegex(ValueError,'terminal_display_failed'):
            pump.push({'type':'started'},'next')
        pump.finish()

    def test_no_cross_application_or_session(self):
        view = TrialView('demo', 'selected-app')
        for p in [segment(track='mic', session='other'), segment(track='remote', application='other')]:
            with self.assertRaises(ValueError): view.receive(p)


if __name__ == '__main__': unittest.main()

class ScopeRequestTests(unittest.TestCase):
    def test_new_scope_requires_confirmation_before_native(self):
        from gui_worker import validate_request
        request={'bundle':'*system*','key':'fake','user_launch_confirmed':True}
        with self.assertRaises(ValueError):validate_request(request,0,106.31)
        request['source_scope_confirmed']=True
        c=validate_request(request,0,106.31)
        self.assertEqual(c['bundle'],'*system*');self.assertTrue(c['micEnabled']);self.assertEqual(c['maxSeconds'],373)
        request['mic_enabled']=False
        self.assertFalse(validate_request(request,0,106.31)['micEnabled'])
    def test_scope_never_overrides_budget_and_rejects_own_app(self):
        from gui_worker import validate_request
        r={'bundle':'fake.browser','key':'fake','user_launch_confirmed':True,'source_scope_confirmed':True}
        with self.assertRaises(ValueError):validate_request(r,0,480)
        r['bundle']='com.zaichang.app'
        with self.assertRaises(ValueError):validate_request(r,0,0)
        r['bundle']='fake.browser';r['mic_enabled']='false'
        with self.assertRaises(ValueError):validate_request(r,0,0)

class SpeakerDiagnosticPrivacy(unittest.TestCase):
    def test_counts_allowed_audio_features_text_and_unknown_fields_removed(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'health.json'
            writer=live_trial.HealthWriter('offline','synthetic',10,0,path=path)
            writer.observe({'type':'health','elapsed_seconds':1,'mic':{'speaker_single_frames':12,'speaker_unknown_no_speaker_evidence':2,'speaker_frames_total':'secret-text','identity_features':[1,2],'pcm':'secret-pcm','text':'private-body','speaker_unknown_arbitrary':'private-body'},'remote':{}})
            data=json.loads(path.read_text());track=data['tracks']['mic']
            self.assertEqual(track['speaker_single_frames'],12);self.assertEqual(track['speaker_unknown_no_speaker_evidence'],2)
            self.assertNotIn('speaker_frames_total',track);self.assertNotIn('identity_features',track);self.assertNotIn('private-body',path.read_text());self.assertNotIn('secret-pcm',path.read_text())

class BufferedProcessingDeadline(unittest.TestCase):
    def test_processing_grace_never_renews_capture_and_duplicate_does_not_extend(self):
        deadline=live_trial.TrialDeadline(180,100)
        self.assertFalse(deadline.processing_started(101))
        self.assertTrue(deadline.recording_started(101));self.assertEqual(deadline.expires_at,286)
        self.assertTrue(deadline.processing_started(281));self.assertEqual(deadline.expires_at,466)
        self.assertFalse(deadline.processing_started(400));self.assertEqual(deadline.expires_at,466)
        self.assertEqual(deadline.started_at,101)
    def test_processing_metadata_preserves_recording_budget_not_model_wall_time(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'health.json';writer=live_trial.HealthWriter('offline','synthetic',180,0,path=file)
            writer.observe({'type':'started'})
            writer.observe({'type':'capture_stopped','recording_elapsed_seconds':180.05,'reason':'trial_time_limit'})
            self.assertEqual(writer.values['phase'],'processing');self.assertEqual(writer.values['elapsed_seconds'],180.05)
            writer.observe({'type':'processing_started','recording_elapsed_seconds':180.05})
            writer.observe({'type':'stopped','recording_elapsed_seconds':180.05,'received_at':250,'reason':'trial_time_limit'})
            self.assertEqual(writer.values['elapsed_seconds'],180.05)
