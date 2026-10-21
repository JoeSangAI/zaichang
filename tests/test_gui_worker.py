import unittest
import tempfile
import json
from pathlib import Path
from unittest.mock import patch
import gui_worker
import live_trial

class GUIContract(unittest.TestCase):
    def test_append_capture_reuses_session_and_confirmed_terms(self):
        import uuid
        with tempfile.TemporaryDirectory() as folder,patch.object(Path,'home',return_value=Path(folder)):
            cache_id=str(uuid.uuid4())
            cache=Path(folder)/'Library/Application Support/ZaichangStandalone/SessionCache'/cache_id
            cache.mkdir(parents=True)
            cache.joinpath('meeting.json').write_text(json.dumps(dict(session='same-session',bundle='*system*',
                asr_model='qwen-audio-3.0-asr-flash-streaming',capture_mode='cloud',
                asr_vocabulary_confirmed=True,asr_vocabulary={'虚构姓名甲':5})))
            request=dict(bundle='*system*',key='synthetic-test',cloud_session_confirmed=True,
                         user_launch_confirmed=True,source_scope_confirmed=True,mic_enabled=True,
                         append_capture_cache_id=cache_id)
            with patch('shared_terms.auto_vocabulary',return_value={'项目词':4}) as automatic:
                config=gui_worker.cloud_session_config(request)
            self.assertEqual(config['session'],'same-session')
            self.assertEqual(config['appendCaptureCacheID'],cache_id)
            # Standing project words come first; the earlier part's saved words are kept.
            self.assertEqual(config['asrVocabulary'],{'项目词':4,'虚构姓名甲':5})
            self.assertEqual(automatic.call_args.args,(None,))
            self.assertTrue(config['asrVocabularyConfirmed'])
            self.assertTrue(gui_worker.is_transcript_track('mic-g1'))
            request['resume_cache_id']=cache_id
            with self.assertRaises(ValueError):
                gui_worker.cloud_session_config(request)
            cache.joinpath('meeting.json').write_text(json.dumps(dict(session='same-session',bundle='*system*',
                asr_model='qwen-audio-3.0-asr-flash-streaming',capture_mode='local_only',upload_authorized=True)))
            local=dict(bundle='*system*',local_only=True,local_recording_confirmed=True,
                       user_launch_confirmed=True,source_scope_confirmed=True,mic_enabled=True,
                       append_capture_cache_id=cache_id)
            self.assertEqual(gui_worker.local_recording_config(local)['session'],'same-session')
    def test_capture_status_exposes_only_valid_per_track_counters(self):
        health={'type':'health','session':'s','mic':{'pcm_bytes':32000,'internal':'hidden'},'remote':{'pcm_bytes':0},'secret':'not-forwarded'}
        self.assertEqual(gui_worker.capture_status_event(health),{'type':'capture_status','session':'s','tracks':{'mic':32000,'remote':0}})
        for value in (-1, True, '32000', None):
            self.assertIsNone(gui_worker.capture_status_event({'type':'health','mic':{'pcm_bytes':value}}))
        self.assertIsNone(gui_worker.capture_status_event({'type':'segment','mic':{'pcm_bytes':32000}}))
    def test_zero_mic_signal_remains_independent_of_remote_and_asr(self):
        raw={'hardware_pcm_frames':80,'signal_samples':128000,'nonzero_samples':0,'signal_rms':0,'signal_peak':0}
        source={'pcm_bytes':256000,'hardware_pcm_frames':80,'nonzero_samples':4000,'signal_rms':.1}
        mic={'pcm_bytes':256000,'raw_signal':raw,'input_diagnostics':{'input_nonzero_samples':0},'private':'hidden'}
        event=gui_worker.capture_status_event({'type':'health','session':'wechat','elapsed_seconds':9,'paused':False,'mic':mic,'app-123456789abcdef0-g1':source})
        self.assertEqual(event['signal']['mic']['raw_signal'],raw)
        self.assertEqual(event['signal']['mic']['input_diagnostics']['input_nonzero_samples'],0)
        self.assertNotIn('private',event['signal']['mic'])
        self.assertEqual(event['elapsed_seconds'],9)

    def request(self,**kw):
        return dict({'bundle':'com.tencent.meeting','key':'synthetic-test','user_launch_confirmed':True},**kw)
    def test_legacy_trial_wall_window_remains_but_audio_cost_does_not_gate(self):
        config=gui_worker.validate_request(self.request(),189.764125,106.306888)
        self.assertEqual(config['maxSeconds'],373)
        self.assertEqual(gui_worker.validate_request(self.request(),400000,100)['maxSeconds'],380)
        for audio,wall in [(0,480),(4000,100000)]:
            with self.assertRaises(ValueError):gui_worker.validate_request(self.request(),audio,wall)
    def test_missing_key_scope_and_intent_no_launch(self):
        for change in [{'key':''},{'bundle':'other.app'},{'user_launch_confirmed':False}]:
            with self.assertRaises(ValueError):gui_worker.validate_request(self.request(**change),0,0)
    def test_single_instance_prevents_second_entry(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(live_trial,'__file__',str(Path(folder)/'live_trial.py')):
                (Path(folder)/'native/build').mkdir(parents=True)
                first=live_trial.single_instance()
                try:
                    with self.assertRaises(ValueError):live_trial.single_instance()
                finally:first.close()
    def test_crash_reserves_remaining_and_inflight_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'health.json'
            p.write_text(json.dumps({'phase':'active','previous_wall_seconds':106.3,'elapsed_seconds':5,
                'max_seconds':373,'tracks':{'mic':{'sent_audio_seconds':1,'attempted_audio_seconds':2}}}))
            audio,wall=live_trial.prior_totals(p)
            self.assertEqual(audio,2)
            self.assertAlmostEqual(wall,479.3)
            with self.assertRaises(ValueError):gui_worker.validate_request(self.request(),audio,wall)
if __name__=='__main__':unittest.main()

class LocalModelRequest(unittest.TestCase):
    def test_optional_model_never_resets_budget_or_auto_enables(self):
        request={'bundle':'com.tencent.meeting','key':'synthetic-test','user_launch_confirmed':True}
        config=gui_worker.validate_request(request,189.764125,106.306888)
        self.assertNotIn('localSpeakerDirectory',config)
        request['speaker_enabled']=True
        with patch.object(Path,'is_file',return_value=True):
            config=gui_worker.validate_request(request,189.764125,106.306888)
        self.assertEqual(config['maxSeconds'],373)
        self.assertTrue(config['localSpeakerDirectory'].endswith('native/local-speaker-install/runtime-models'))
        self.assertTrue(config['localEmbeddingModel'].endswith('3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx'))
    def test_invalid_enable_or_missing_model_rejects_before_launch(self):
        request={'bundle':'com.tencent.meeting','key':'synthetic-test','user_launch_confirmed':True,'speaker_enabled':'yes'}
        with self.assertRaises(ValueError):gui_worker.validate_request(request,0,0)
        request['speaker_enabled']=True
        with patch.object(Path,'is_file',return_value=False):
            with self.assertRaises(ValueError):gui_worker.validate_request(request,0,0)

class StartupDeadline(unittest.TestCase):
    def test_cold_load_is_not_recording_and_duplicate_start_never_extends(self):
        d=live_trial.TrialDeadline(180,100)
        self.assertEqual(d.expires_at,145)
        self.assertTrue(d.recording_started(112))
        self.assertEqual(d.expires_at,297)
        self.assertFalse(d.recording_started(150))
        self.assertEqual(d.expires_at,297)

class CandidateTrial(unittest.TestCase):
    def request(self,**changes):
        return dict(bundle='com.tencent.meeting',key='synthetic-test',user_launch_confirmed=True,
                    mic_enabled=True,speaker_enabled=True,candidate_mode=True,**changes)
    def test_180_seconds_with_existing_cumulative_budget(self):
        request=self.request()
        with tempfile.TemporaryDirectory() as folder:
            allowance=Path(folder)/'allowance.json';allowance.write_text(json.dumps({'baseline_wall_seconds':118.6744922916696,'max_candidate_wall_seconds':180}))
            with patch.object(gui_worker,'ALLOWANCE_FILE',allowance), patch.object(Path,'is_file',return_value=True):
                config=gui_worker.validate_request(request,199.147375,118.6744922916696)
                self.assertEqual(config['maxSeconds'],180)
                self.assertEqual(config['bundle'],'com.tencent.meeting')
                self.assertTrue(config['micEnabled'])
                self.assertEqual(gui_worker.validate_request(request,199.147375,268.6744922916696)['maxSeconds'],30)
    def test_new_scope_and_persistent_snapshot_rejected(self):
        for key,value in [('bundle','*system*'),('mic_enabled',False),('speaker_enabled',False),('identity_snapshot',{})]:
            request=self.request();request[key]=value
            with self.assertRaises(ValueError):gui_worker.validate_request(request,0,0)
    def test_unarmed_native_never_launched(self):
        import plistlib
        with tempfile.TemporaryDirectory() as temp:
            binary=Path(temp)/'Contents/MacOS/MeetingCapture';binary.parent.mkdir(parents=True)
            (binary.parent.parent/'Info.plist').write_bytes(plistlib.dumps({'TrialArmed':False,'OfflineOnly':False}))
            with patch.object(gui_worker,'CANDIDATE',binary):
                with self.assertRaisesRegex(ValueError,'等待本人'):gui_worker.candidate_binary(self.request())
                (binary.parent.parent/'Info.plist').write_bytes(plistlib.dumps({'TrialArmed':True,'OfflineOnly':False}))
                self.assertEqual(gui_worker.candidate_binary(self.request()),binary)
                self.assertEqual(gui_worker.candidate_binary({}),gui_worker.NATIVE)
                (binary.parent.parent/'Info.plist').write_bytes(plistlib.dumps({'TrialArmed':False,'ClickStartsTrial':True,'OfflineOnly':False}))
                self.assertEqual(gui_worker.candidate_binary(dict(self.request(),user_launch_confirmed=True)),binary)
                with self.assertRaises(ValueError):gui_worker.candidate_binary(dict(self.request(),user_launch_confirmed=False))

class TemporaryCandidatePeople(unittest.TestCase):
    def test_preserves_only_preconfirmed_labels_and_ephemeral_consent(self):
        draft={'people':{'p':'知情测试人物'},'consents':{'p':{'consent_id':'consent-test','active':True,'persistent_allowed':False,'purpose':'local_identity_until_app_exit'}}}
        state=gui_worker.temporary_people({'candidate_mode':True,'human_identity_confirmed':True,'candidate_people':draft})
        self.assertEqual(state['people'],draft['people']);self.assertEqual(state['consents'],draft['consents'])
        self.assertEqual(state['samples'],[]);self.assertIsNone(state['calibration']);self.assertEqual(state['journal'],[])
    def test_long_profiles_or_unconfirmed_draft_cannot_enter_live_candidate(self):
        for request in [
            {'candidate_mode':True,'candidate_people':{}},
            {'candidate_mode':True,'human_identity_confirmed':True,'candidate_people':{'samples':[]}},
            {'candidate_mode':True,'human_identity_confirmed':True,'candidate_people':{'consents':{'p':{'persistent_allowed':True,'purpose':'local_cross_meeting_identity'}}}}]:
            with self.assertRaises(ValueError):gui_worker.temporary_people(request)

class CandidateCumulativeAllowance(unittest.TestCase):
    def test_stop_reopen_and_rebuild_do_not_grant_another_180_seconds(self):
        request={'bundle':'com.tencent.meeting','key':'synthetic-test','user_launch_confirmed':True,'mic_enabled':True,'speaker_enabled':True,'candidate_mode':True}
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)/'allowance.json';p.write_text(json.dumps({'baseline_wall_seconds':118.6744922916696,'max_candidate_wall_seconds':180}))
            with patch.object(gui_worker,'ALLOWANCE_FILE',p),patch.object(Path,'is_file',return_value=True):
                self.assertEqual(gui_worker.validate_request(request,199.147375,218.6744922916696)['maxSeconds'],80)
                with self.assertRaisesRegex(ValueError,'180秒测试额度'):gui_worker.validate_request(request,199.147375,298.6744922916696)

class FacingMeetingScope(unittest.TestCase):
    def test_mic_only_explicit_selection_and_budget_guard(self):
        request={'bundle':'*microphone*','key':'synthetic-test','user_launch_confirmed':True,'mic_enabled':True,'speaker_enabled':True}
        with self.assertRaises(ValueError):gui_worker.validate_request(request,0,0)
        request['source_scope_confirmed']=True
        with patch.object(Path,'is_file',return_value=True):
            config=gui_worker.validate_request(request,0,100)
        self.assertEqual(config['bundle'],'*microphone*');self.assertTrue(config['micEnabled']);self.assertIn('localSpeakerDirectory',config)
        request['mic_enabled']=False
        with self.assertRaises(ValueError):gui_worker.validate_request(request,0,0)
        request['mic_enabled']=True;request['candidate_mode']=True
        with tempfile.TemporaryDirectory() as folder:
            allowance=Path(folder)/'allowance.json';allowance.write_text(json.dumps({'baseline_wall_seconds':118.6744922916696,'max_candidate_wall_seconds':180}))
            with patch.object(gui_worker,'ALLOWANCE_FILE',allowance),patch.object(Path,'is_file',return_value=True):
                with self.assertRaisesRegex(ValueError,'180秒测试额度'):gui_worker.validate_request(request,557.366,298.75397804167)

class RecoveryRequest(unittest.TestCase):
    def request(self,cache_id):
        return {'bundle':'*microphone*','mic_enabled':True,'key':'synthetic-test','user_launch_confirmed':True,'source_scope_confirmed':True,'resume_cache_id':cache_id}
    def test_exhausted_budget_rejects_before_reading_cache(self):
        with patch.object(Path,'home',side_effect=AssertionError('cache must not be inspected')):
            with self.assertRaises(ValueError):gui_worker.validate_request(self.request('00000000-0000-0000-0000-000000000001'),0,480)
    def test_existing_scope_resumes_without_running_meeting_app(self):
        import uuid
        with tempfile.TemporaryDirectory() as folder:
            cache_id=str(uuid.uuid4());root=Path(folder);directory=root/'Library/Application Support/ZaichangStandalone/SessionCache'/cache_id;directory.mkdir(parents=True)
            (directory/'meeting.json').write_text(json.dumps({'session':'previous-session','bundle':'*microphone*','asr_destination':'dashscope.aliyuncs.com','asr_model':'qwen-audio-3.0-asr-flash-streaming'}))
            with patch.object(Path,'home',return_value=root):
                config=gui_worker.validate_request(self.request(cache_id),0,0)
                self.assertEqual(config['resumeCacheID'],cache_id);self.assertEqual(config['session'],'previous-session')
                (directory/'meeting.json').write_text(json.dumps({'session':'previous-session','bundle':'*microphone*','asr_destination':'unknown.example','asr_model':'qwen-audio-3.0-asr-flash-streaming'}))
                with self.assertRaisesRegex(ValueError,'范围变化'):gui_worker.validate_request(self.request(cache_id),0,0)
    def test_recovery_scope_path_cannot_escape_or_follow_session_symlink(self):
        with self.assertRaises(ValueError):gui_worker.validate_request(self.request('../other'),0,0)
        import uuid
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);cache_id=str(uuid.uuid4());base=root/'Library/Application Support/ZaichangStandalone/SessionCache';base.mkdir(parents=True);(base/cache_id).symlink_to(root,target_is_directory=True)
            with patch.object(Path,'home',return_value=root):
                with self.assertRaises(ValueError):gui_worker.validate_request(self.request(cache_id),0,0)

class LocalRecordingContract(unittest.TestCase):
    def request(self):
        return dict(local_only=True,local_recording_confirmed=True,user_launch_confirmed=True,source_scope_confirmed=True,bundle='*microphone*',mic_enabled=True,key='',local_max_seconds=3600,candidate_mode=True)
    def test_exhausted_cloud_budget_does_not_block_local_recording(self):
        cfg=gui_worker.validate_request(self.request(),1000000,1000000)
        self.assertTrue(cfg['localOnly']);self.assertTrue(cfg['unlimitedSession']);self.assertEqual(cfg['key'],'');self.assertEqual(cfg['maxSeconds'],3600)
        self.assertNotIn('localSpeakerDirectory',cfg)
    def test_local_mode_needs_explicit_click_and_scope_and_no_cloud_secret(self):
        for field,value in [('local_recording_confirmed',False),('user_launch_confirmed',False),('source_scope_confirmed',False),('mic_enabled',False),('key','must-not-use-cloud-key'),('local_max_seconds',float('inf'))]:
            req=self.request();req[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):gui_worker.validate_request(req,0,0)
    def test_local_system_plus_mic_and_hard_duration_limit(self):
        req=self.request();req['bundle']='*system*';self.assertEqual(gui_worker.validate_request(req,0,0)['bundle'],'*system*')
        req['local_max_seconds']=7201
        with self.assertRaises(ValueError):gui_worker.validate_request(req,0,0)
    def test_local_resume_cannot_silently_upload(self):
        req=self.request();req['resume_cache_id']='already-local'
        with self.assertRaises(ValueError):gui_worker.validate_request(req,0,0)

class IndependentCloudSessionContract(unittest.TestCase):
    def request(self):
        return dict(cloud_session_confirmed=True,cloud_budget_yuan=5,user_launch_confirmed=True,source_scope_confirmed=True,bundle='*microphone*',mic_enabled=True,key='fixture-not-a-real-key',candidate_mode=True)
    def test_new_cloud_session_keeps_legacy_budget_field_optional(self):
        cfg=gui_worker.validate_request(self.request(),1000000,1000000)
        self.assertTrue(cfg['cloudSessionConfirmed']);self.assertEqual(cfg['maxSeconds'],7200);self.assertTrue(cfg['unlimitedSession'])
        req=self.request();req.pop('cloud_budget_yuan');self.assertTrue(gui_worker.cloud_session_config(req)['unlimitedSession'])
    def test_cloud_session_requires_scope_and_mic_but_ignores_legacy_budget_field(self):
        for field,value in [('cloud_session_confirmed',False),('source_scope_confirmed',False),('user_launch_confirmed',False),('mic_enabled',False)]:
            req=self.request();req[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):gui_worker.cloud_session_config(req)
        req=self.request();req['cloud_budget_yuan']=50
        self.assertTrue(gui_worker.cloud_session_config(req)['unlimitedSession'])
    def test_resume_ignores_cumulative_amount_and_duration_gates(self):
        import uuid
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);cid=str(uuid.uuid4());directory=root/'Library/Application Support/ZaichangStandalone/SessionCache'/cid;directory.mkdir(parents=True)
            metadata=dict(session='same-session',bundle='*microphone*',asr_model='qwen-audio-3.0-asr-flash-streaming',asr_destination='dashscope.aliyuncs.com',cloud_session_authorized=True,cloud_audio_ceiling_seconds=14400)
            (directory/'meeting.json').write_text(json.dumps(metadata));(directory/'mic-manifest.json').write_text('{}');(directory/'remote-manifest.json').write_text('{}')
            req=self.request();req['resume_cache_id']=cid
            with patch.object(Path,'home',return_value=root):
                (directory/'session-usage.json').write_text(json.dumps({'cumulative_input_audio_seconds':900000,'cumulative_estimated_yuan':'999'}))
                cfg=gui_worker.cloud_session_config(req);self.assertEqual(cfg['session'],'same-session');self.assertEqual(cfg['maxSeconds'],7200);self.assertTrue(cfg['unlimitedSession']);self.assertNotIn('remainingUploadSeconds',cfg)
                (directory/'session-usage.json').write_text('{broken')
                self.assertTrue(gui_worker.cloud_session_config(req)['unlimitedSession'])
    def test_resume_cost_ledgers_never_gate_and_corruption_is_unknown_to_stats(self):
        import uuid
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);cid=str(uuid.uuid4());directory=root/'Library/Application Support/ZaichangStandalone/SessionCache'/cid;directory.mkdir(parents=True)
            metadata=dict(session='same-session',bundle='*microphone*',asr_model='qwen-audio-3.0-asr-flash-streaming',asr_destination='dashscope.aliyuncs.com',cloud_session_authorized=True,cloud_audio_ceiling_seconds=14400)
            (directory/'meeting.json').write_text(json.dumps(metadata));(directory/'mic-manifest.json').write_text('{}')
            (directory/'session-usage.json').write_text(json.dumps({'cumulative_input_audio_seconds':13000,'cumulative_estimated_yuan':'4.29'}))
            req=self.request();req['resume_cache_id']=cid
            with patch.object(Path,'home',return_value=root):
                ledger=directory/'coarse-audio-progress.json'
                ledger.write_text(json.dumps({'schema':1,'session':'same-session','cache_id':cid,'budget_yuan':1,'reserved_yuan':'0.5','segments':{}}))
                cfg=gui_worker.cloud_session_config(req)
                self.assertEqual(cfg['maxSeconds'],7200)
                ledger.write_text(json.dumps({'schema':1,'session':'same-session','cache_id':cid,'budget_yuan':1,'reserved_yuan':'0.71','segments':{}}))
                self.assertTrue(gui_worker.cloud_session_config(req)['unlimitedSession'])
                ledger.write_text('{broken')
                self.assertTrue(gui_worker.cloud_session_config(req)['unlimitedSession'])
    def test_many_source_generations_do_not_divide_remaining_budget(self):
        import uuid
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);cid=str(uuid.uuid4());directory=root/'Library/Application Support/ZaichangStandalone/SessionCache'/cid;directory.mkdir(parents=True)
            (directory/'meeting.json').write_text(json.dumps(dict(session='same-session',bundle='*microphone*',asr_model='qwen-audio-3.0-asr-flash-streaming',asr_destination='dashscope.aliyuncs.com',cloud_session_authorized=True,cloud_audio_ceiling_seconds=14400)))
            for i in range(1,81):(directory/f'remote-g{i}-manifest.json').write_text('{}')
            (directory/'session-usage.json').write_text(json.dumps({'cumulative_input_audio_seconds':14000}))
            req=self.request();req['resume_cache_id']=cid
            with patch.object(Path,'home',return_value=root):
                cfg=gui_worker.cloud_session_config(req)
            self.assertEqual(cfg['maxSeconds'],7200);self.assertTrue(cfg['unlimitedSession'])

    def test_local_pending_resume_requires_upload_confirmation(self):
        import uuid
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);cid=str(uuid.uuid4());directory=root/'Library/Application Support/ZaichangStandalone/SessionCache'/cid;directory.mkdir(parents=True)
            (directory/'meeting.json').write_text(json.dumps(dict(session='local-session',bundle='*microphone*',asr_model='qwen-audio-3.0-asr-flash-streaming',capture_mode='local_only',upload_authorized=False)))
            (directory/'mic-manifest.json').write_text('{}');req=self.request();req['resume_cache_id']=cid
            with patch.object(Path,'home',return_value=root):
                with self.assertRaisesRegex(ValueError,'local_audio_upload_not_confirmed'):gui_worker.cloud_session_config(req)
                req['resume_upload_confirmed']=True;cfg=gui_worker.cloud_session_config(req);self.assertTrue(cfg['resumeUploadConfirmed']);self.assertEqual(cfg['session'],'local-session')

class PackagedWorkerLock(unittest.TestCase):
    def test_worker_main_uses_user_temp_lock_without_bundle_writes(self):
        import io
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);bundle=root/'ReadonlyBundle';bundle.mkdir();bundle.chmod(0o500)
            with patch.object(gui_worker.tempfile,'gettempdir',return_value=str(root)),patch.object(gui_worker.sys,'argv',['gui_worker.py']),patch.object(gui_worker.sys,'stdin',io.StringIO('{}\n')),patch.object(gui_worker,'execute') as execute:
                gui_worker.main();execute.assert_called_once_with({})
            self.assertTrue((root/('zaichang-meeting-worker-'+str(gui_worker.os.getuid())+'.lock')).is_file());self.assertEqual(list(bundle.iterdir()),[])
    def test_lock_rejects_symlink_and_preserves_target(self):
        import live_trial
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);target=root/'target';target.write_text('fixture unchanged');link=root/'lock';link.symlink_to(target)
            with self.assertRaises(OSError):live_trial.single_instance(link)
            self.assertEqual(target.read_text(),'fixture unchanged')
    def test_scoped_temp_lock_rejects_duplicate_worker(self):
        import live_trial
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'worker.lock';first=live_trial.single_instance(path)
            try:
                with self.assertRaises(ValueError):live_trial.single_instance(path)
            finally:first.close()


class RecordingControlReceipt(unittest.TestCase):
    def test_capture_terminal_events_close_receipt_gates_and_resume_reopens(self):
        receipt=gui_worker.recording_control_snapshot(
            dict(type='started',session='s',capture=True),None,'s')
        self.assertEqual((receipt['capture_gate'],receipt['upload_gate']),('open','open'))
        self.assertTrue(receipt['capture_session_active'])
        receipt=gui_worker.recording_control_snapshot(
            dict(type='capture_stopped',session='s',reason='cache_writer_backpressure',
                 upload_gate='draining_saved_audio'),receipt,'s')
        self.assertEqual((receipt['capture_gate'],receipt['upload_gate']),('closed','draining_saved_audio'))
        self.assertFalse(receipt['capture_session_active'])
        # A user continuation is an explicit new capture transition.
        receipt=gui_worker.recording_control_snapshot(
            dict(type='recording_resumed',session='s',control_revision=2),receipt,'s')
        self.assertEqual((receipt['capture_gate'],receipt['upload_gate']),('open','open'))
        self.assertTrue(receipt['capture_session_active'])
        receipt=gui_worker.recording_control_snapshot(
            dict(type='stopped',session='s',reason='user_finish'),receipt,'s')
        self.assertEqual((receipt['capture_gate'],receipt['upload_gate']),('closed','closed'))
        self.assertFalse(receipt['capture_session_active'])

    def test_unexpected_helper_exit_closes_open_and_paused_capture(self):
        exit_snapshot=gui_worker.helper_exit_snapshot(0,recorded_at='2026-10-21T00:00:00Z')
        for receipt in (
                dict(last_event='recording_resumed',capture_session_active=True,
                     capture_gate='open',upload_gate='open',control_revision=4),
                dict(last_event='recording_paused',capture_session_active=True,
                     capture_gate='closed',upload_gate='draining_saved_audio',control_revision=5)):
            stopped=gui_worker.finalize_control_receipt_on_exit(receipt,exit_snapshot)
            self.assertEqual((stopped['capture_gate'],stopped['upload_gate']),('closed','closed'))
            self.assertFalse(stopped['capture_session_active'])
            self.assertEqual(stopped['capture_failure']['event'],'helper_exit')
            self.assertEqual(stopped['capture_failure']['control_revision'],receipt['control_revision'])
        clean=gui_worker.finalize_control_receipt_on_exit(
            dict(last_event='stopped',capture_session_active=False,
                 capture_gate='closed',upload_gate='closed'),exit_snapshot)
        self.assertNotIn('capture_failure_reason',clean)

    def test_resume_replaces_stale_ended_marker_with_active_marker(self):
        import json
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as folder:
            cache=Path(folder)
            marker=cache/'meeting-lifecycle.json'
            marker.write_text(json.dumps({'schema':1,'lifecycle':'ended','session':'s'}))
            gui_worker.persist_active_meeting_lifecycle(
                cache,'s',678.4,at='2026-10-21T00:00:00Z')
            value=json.loads(marker.read_text())
            self.assertEqual(value,{'schema':1,'lifecycle':'active','session':'s',
                                    'recording_elapsed_seconds':678.4,
                                    'resumed_at':'2026-10-21T00:00:00Z'})
            self.assertEqual(marker.stat().st_mode & 0o777,0o600)

    def test_capture_gap_survives_resume_stop_and_recovery_without_private_fields(self):
        event = dict(type='recording_paused', session='s', control_revision=1,
                     coverage_gap=True, gap_reason='mic_conversion_backpressure', gap_seconds=0.4)
        receipt = gui_worker.recording_control_snapshot(event, None, 's')
        self.assertEqual(receipt['gap_seconds'], 0.4)
        self.assertIsNone(gui_worker.recording_control_snapshot(event, receipt, 's'))
        for event in (dict(type='recording_resumed', session='s', control_revision=2),
                      dict(type='stopped', session='s', reason='user_finish')):
            receipt = gui_worker.recording_control_snapshot(event, receipt, 's')
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp)
            (cache / 'recording-control.json').write_text(json.dumps(dict(receipt, text='private')))
            recovered = gui_worker.initial_control_receipt(cache, 's', recovery=True)
            self.assertTrue(recovered['coverage_gap'])
            self.assertEqual(recovered['gap_seconds'], 0.4)
            self.assertNotIn('text', recovered)
        for invalid in (True, -1, float('nan'), float('inf'), '0.4'):
            self.assertIsNone(gui_worker.safe_capture_gap(dict(
                coverage_gap=True, gap_reason='mic_conversion_backpressure', gap_seconds=invalid)))

    def test_pause_ack_is_delivered_before_early_tail_from_ordinary_stdout(self):
        delivery = gui_worker.PauseControlEventDelivery()
        tail = dict(type='recording_pause_tail', session='s', pause_revision=7,
                    track='mic', state='complete')
        ack = dict(type='recording_paused', session='s', control_revision=7,
                   capture_gate='closed', upload_gate='draining_saved_audio',
                   draining_tracks=['mic'])
        delivery.tail(tail)
        delivery.acknowledge(ack)
        self.assertEqual(delivery.receive(), ack)
        self.assertEqual(delivery.receive(), tail)
        delivery.tail(dict(tail, track='remote'))
        self.assertEqual(delivery.receive()['track'], 'remote')

    def test_pause_and_finished_sources_leave_bounded_receipt(self):
        event = dict(type='recording_paused', session='s', control_revision=3,
                     capture_gate='closed', upload_gate='draining_saved_audio',
                     draining_tracks=['mic', 'remote-g1', 'reference'],
                     ack_transport='dedicated_socket', text='private', key='secret')
        snapshot = gui_worker.recording_control_snapshot(event, None, 's')
        self.assertEqual(snapshot['pause_tracks'], {'mic': 'processing', 'remote-g1': 'processing'})
        self.assertEqual(snapshot['ack_transport'], 'dedicated_socket')
        self.assertNotIn('text', snapshot)
        self.assertNotIn('key', snapshot)
        for track in ('remote-g1', 'mic'):
            snapshot = gui_worker.recording_control_snapshot(dict(type='recording_pause_tail',
                session='s', pause_revision=3, track=track, state='complete'), snapshot, 's')
        self.assertEqual(set(snapshot['pause_tracks'].values()), {'complete'})
        failed = gui_worker.recording_control_snapshot(dict(type='stopped', session='s',
            reason='capture_control_timeout_pause_drain', transcription_complete=False), snapshot, 's')
        self.assertEqual(failed['reason'], 'capture_control_timeout_pause_drain')
        self.assertEqual(failed['pause_tracks'], snapshot['pause_tracks'])

    def test_first_capture_failure_survives_later_successful_recovery_stop(self):
        failed = gui_worker.recording_control_snapshot(dict(type='recording_control_failed',
            session='s', action='pause', reason='capture_pause_teardown_timeout'), None, 's')
        recovered = gui_worker.recording_control_snapshot(dict(type='stopped', session='s',
            reason='user_finish', transcription_complete=True), failed, 's')
        self.assertEqual(recovered['capture_failure_reason'], 'capture_pause_teardown_timeout')
        self.assertEqual(recovered['capture_failure'], failed['capture_failure'])
        self.assertTrue(recovered['transcription_complete'])

    def test_capture_control_failed_is_receipted_but_processing_failures_are_not_capture_failures(self):
        failed = gui_worker.recording_control_snapshot(dict(type='capture_control_failed',
            session='s', reason='capture_signal_channel_failed'), None, 's')
        self.assertEqual(failed['capture_failure_reason'], 'capture_signal_channel_failed')
        for reason in ('processing_timeout', 'processing_cancelled'):
            stopped = gui_worker.recording_control_snapshot(dict(type='stopped', session='s',
                reason=reason, transcription_complete=False), None, 's')
            self.assertNotIn('capture_failure_reason', stopped)

    def test_recovery_stop_carries_only_same_session_structured_capture_cause(self):
        self.assertEqual(gui_worker.control_event_for_ui(
            {'type':'stopped','reason':'user_finish','transcription_complete':True},
            recovery=True,source_capture_failure_reason='capture_pause_teardown_timeout'),
            {'type':'stopped','reason':'user_finish','transcription_complete':True,
             'capture_failure_reason':'capture_pause_teardown_timeout'})
        self.assertNotIn('capture_failure_reason',gui_worker.control_event_for_ui(
            {'type':'stopped','reason':'user_finish'},recovery=False,
            source_capture_failure_reason='capture_pause_teardown_timeout'))
        self.assertNotIn('capture_failure_reason',gui_worker.control_event_for_ui(
            {'type':'stopped','reason':'user_finish'},recovery=True,
            source_capture_failure_reason='秘密内容'))

    def test_same_session_recovery_receipt_does_not_overwrite_original_capture_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            cache=Path(temp);session='same-session';original=cache/'recording-control.json'
            prior={'schema':1,'session':session,'last_event':'stopped',
                   'capture_failure_reason':'capture_control_timeout_pause',
                   'capture_failure':{'reason':'capture_control_timeout_pause','event':'stopped'}}
            original.write_text(json.dumps(prior))
            receipt=gui_worker.initial_control_receipt(cache,session,recovery=True)
            last_recovery=gui_worker.append_control_request(receipt['last_recovery'],session,
                'resume',accepted=True,source='ui')
            last_recovery.pop('schema',None);last_recovery.pop('session',None)
            receipt=dict(receipt,last_recovery=last_recovery)
            gui_worker.write_control_receipt(cache,receipt)
            stored=json.loads(original.read_text())
            self.assertEqual(stored['capture_failure_reason'],'capture_control_timeout_pause')
            self.assertEqual(stored['last_event'],'stopped')
            self.assertEqual(stored['last_recovery']['last_request']['action'],'resume')
            self.assertIn('requested_at',stored['last_recovery']['last_request'])
            self.assertNotIn('requests',stored)
            self.assertNotIn('session',stored['last_recovery'])
            self.assertFalse((cache/'recording-control-recovery.json').exists())
            self.assertNotIn('key',stored)
            self.assertNotIn('text',stored)

    def test_successful_recovery_is_nested_and_keeps_original_failure_owner(self):
        prior={'schema':1,'session':'same-session','last_event':'stopped',
               'reason':'capture_control_timeout_pause',
               'capture_failure_reason':'capture_control_timeout_pause',
               'capture_failure':{'reason':'capture_control_timeout_pause','event':'stopped'}}
        with tempfile.TemporaryDirectory() as temp:
            cache=Path(temp)
            (cache/'recording-control.json').write_text(json.dumps(prior))
            receipt=gui_worker.initial_control_receipt(cache,'same-session',recovery=True)
            event=gui_worker.control_event_for_ui(
                {'type':'stopped','session':'same-session','reason':'user_finish',
                 'transcription_complete':True},recovery=True,
                source_capture_failure_reason='capture_control_timeout_pause')
            recovery=gui_worker.recording_control_snapshot(
                event,receipt['last_recovery'],'same-session')
            recovery.pop('capture_failure_reason',None)
            recovery.pop('capture_failure',None)
            recovery.pop('schema',None);recovery.pop('session',None)
            receipt=dict(receipt,last_recovery=recovery)
            gui_worker.write_control_receipt(cache,receipt)
            stored=json.loads((cache/'recording-control.json').read_text())
            self.assertEqual(stored['capture_failure_reason'],'capture_control_timeout_pause')
            self.assertEqual(stored['reason'],'capture_control_timeout_pause')
            self.assertEqual(stored['last_recovery']['reason'],'user_finish')
            self.assertTrue(stored['last_recovery']['transcription_complete'])
            self.assertNotIn('capture_failure_reason',stored['last_recovery'])

    def test_local_recording_receipt_path_and_helper_exit_are_structured(self):
        with tempfile.TemporaryDirectory() as temp:
            cache=Path(temp)
            receipt=gui_worker.initial_control_receipt(cache,'local-session')
            receipt=gui_worker.append_control_request(receipt,'local-session','pause',accepted=True)
            gui_worker.write_control_receipt(cache,receipt)
            stored=json.loads((cache/'recording-control.json').read_text())
            self.assertEqual(stored['last_request']['action'],'pause')
            self.assertEqual(stored['session'],'local-session')
            self.assertEqual(gui_worker.helper_exit_snapshot(-9)['reason'],'signal_9')
            self.assertEqual(gui_worker.helper_exit_snapshot(0,'capture_control_timeout_pause')['reason'],
                             'capture_control_timeout_pause')
            self.assertNotIn('audio',json.dumps(gui_worker.helper_exit_snapshot(-9)))

    def test_local_only_helper_events_are_persisted_to_its_session_cache(self):
        import contextlib
        import io
        import os
        import uuid
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);cache_id=str(uuid.uuid4());session='local-only-session'
            cache=root/'Library/Application Support/ZaichangStandalone/SessionCache'/cache_id
            cache.mkdir(parents=True)
            binary=root/'fixture-helper.py'
            binary.write_text('''#!/usr/bin/env python3
import json,signal,sys
signal.signal(signal.SIGINT,lambda *_:None)
config=json.loads(sys.stdin.readline())
print(json.dumps(dict(type="started",session=config["session"],cache_id=config["cache_id"])))
print(json.dumps(dict(type="stopped",session=config["session"],cache_id=config["cache_id"],reason="user_finish",transcription_complete=False)))
''')
            binary.chmod(0o700)
            config={'session':session,'cache_id':cache_id}
            read_fd,write_fd=os.pipe()
            open_stdin=os.fdopen(read_fd,'r')
            with patch.object(Path,'home',return_value=root), patch.object(gui_worker.sys,'stdin',open_stdin):
                with contextlib.redirect_stdout(io.StringIO()):
                    gui_worker.run_independent_session(config,binary,cloud=False)
                receipt=json.loads((cache/'recording-control.json').read_text())
                self.assertEqual(receipt['session'],session)
                self.assertEqual(receipt['reason'],'user_finish')
                self.assertEqual(receipt['helper_exit']['reason'],'exit_0')
                self.assertEqual((cache/'recording-control.json').stat().st_mode & 0o777,0o600)
                os.close(write_fd)
                open_stdin.close()

    def test_unexpected_zero_helper_exit_emits_recoverable_terminal_status(self):
        import contextlib
        import io
        import os
        import uuid
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);cache_id=str(uuid.uuid4());session='unexpected-exit-session'
            cache=root/'Library/Application Support/ZaichangStandalone/SessionCache'/cache_id
            cache.mkdir(parents=True)
            (cache/'meeting-lifecycle.json').write_text(json.dumps(
                {'schema':1,'lifecycle':'ended','session':session}))
            binary=root/'lost-helper.py'
            binary.write_text('''#!/usr/bin/env python3
import json,sys
config=json.loads(sys.stdin.readline())
print(json.dumps(dict(type="started",session=config["session"],cache_id="'''+cache_id+'''",
    capture=True,recording_elapsed_seconds=0.1)))
print(json.dumps(dict(type="capture_stopped",session=config["session"],
    reason="cache_writer_backpressure",capture=False,recording_elapsed_seconds=0.1)))
''')
            binary.chmod(0o700)
            read_fd,write_fd=os.pipe();open_stdin=os.fdopen(read_fd,'r')
            output=io.StringIO()
            try:
                with patch.object(Path,'home',return_value=root),patch.object(gui_worker.sys,'stdin',open_stdin),contextlib.redirect_stdout(output):
                    gui_worker.run_independent_session({'session':session},binary,cloud=False)
                events=[json.loads(line) for line in output.getvalue().splitlines()]
                terminal=[event for event in events if event.get('type')=='stopped']
                self.assertEqual(len(terminal),1)
                self.assertEqual(terminal[0]['reason'],'cache_writer_backpressure')
                self.assertEqual(terminal[0]['capture_failure_reason'],'cache_writer_backpressure')
                receipt=json.loads((cache/'recording-control.json').read_text())
                self.assertEqual(receipt['last_event'],'stopped')
                self.assertEqual((receipt['capture_gate'],receipt['upload_gate']),('closed','closed'))
                self.assertEqual(receipt['capture_failure_reason'],'cache_writer_backpressure')
                lifecycle=json.loads((cache/'meeting-lifecycle.json').read_text())
                self.assertEqual(lifecycle['lifecycle'],'active')
                self.assertEqual(lifecycle['session'],session)
            finally:
                os.close(write_fd);open_stdin.close()

    def test_unexpected_nonzero_helper_exit_emits_recoverable_terminal_status(self):
        import contextlib
        import io
        import os
        import uuid
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);cache_id=str(uuid.uuid4());session='unexpected-nonzero-exit-session'
            cache=root/'Library/Application Support/ZaichangStandalone/SessionCache'/cache_id
            cache.mkdir(parents=True)
            binary=root/'lost-helper.py'
            binary.write_text('''#!/usr/bin/env python3
import json,sys
config=json.loads(sys.stdin.readline())
print(json.dumps(dict(type="started",session=config["session"],cache_id="'''+cache_id+'''",
    capture=True,recording_elapsed_seconds=0.1)),flush=True)
sys.exit(7)
''')
            binary.chmod(0o700)
            read_fd,write_fd=os.pipe();open_stdin=os.fdopen(read_fd,'r')
            output=io.StringIO()
            try:
                with patch.object(Path,'home',return_value=root),patch.object(gui_worker.sys,'stdin',open_stdin),contextlib.redirect_stdout(output):
                    gui_worker.run_independent_session({'session':session},binary,cloud=False)
                events=[json.loads(line) for line in output.getvalue().splitlines()]
                terminal=[event for event in events if event.get('type')=='stopped']
                self.assertEqual(len(terminal),1)
                self.assertEqual(terminal[0]['reason'],'capture_helper_exit_7')
                self.assertTrue(terminal[0]['audio_retained'])
                receipt=json.loads((cache/'recording-control.json').read_text())
                self.assertEqual((receipt['capture_gate'],receipt['upload_gate']),('closed','closed'))
                self.assertFalse(receipt['capture_session_active'])
            finally:
                os.close(write_fd);open_stdin.close()

    def test_recovery_helper_error_survives_nonzero_exit_and_is_persisted(self):
        import contextlib
        import io
        import os
        import uuid
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);cache_id=str(uuid.uuid4());session='failed-recovery-session'
            cache=root/'Library/Application Support/ZaichangStandalone/SessionCache'/cache_id
            cache.mkdir(parents=True)
            binary=root/'error-helper.py'
            binary.write_text('''#!/usr/bin/env python3
import json,sys
config=json.loads(sys.stdin.readline())
print(json.dumps(dict(type="error",code="cache_writer_active")),flush=True)
sys.exit(1)
''')
            binary.chmod(0o700)
            config={'session':session,'resumeCacheID':cache_id}
            read_fd,write_fd=os.pipe();open_stdin=os.fdopen(read_fd,'r')
            output=io.StringIO()
            try:
                with patch.object(Path,'home',return_value=root),patch.object(gui_worker.sys,'stdin',open_stdin),contextlib.redirect_stdout(output):
                    gui_worker.run_independent_session(config,binary,cloud=True)
                events=[json.loads(line) for line in output.getvalue().splitlines()]
                self.assertEqual(events,[dict(type='error',session=session,code='cache_writer_active')])
                receipt=json.loads((cache/'recording-control.json').read_text())
                self.assertEqual(receipt['last_recovery']['last_error'],'cache_writer_active')
                self.assertEqual(receipt['last_recovery']['helper_exit']['return_code'],1)
            finally:
                os.close(write_fd);open_stdin.close()

    def test_signal_handler_defers_stop_while_receipt_lock_is_held(self):
        import contextlib
        import io
        import os
        import signal
        import threading
        import time
        import uuid
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);cache_id=str(uuid.uuid4());session='signal-lock-session'
            cache=root/'Library/Application Support/ZaichangStandalone/SessionCache'/cache_id
            cache.mkdir(parents=True)
            marker=root/'child-received-stop'
            binary=root/'fixture-helper.py'
            binary.write_text('''#!/usr/bin/env python3
import json,os,signal,socket,sys,time
from pathlib import Path
config=json.loads(sys.stdin.readline())
print(json.dumps(dict(type="started",session=config["session"],cache_id=config["cache_id"])),flush=True)
def stopped(*_):
    Path(os.environ["STOP_MARKER"]).write_text("received")
    print(json.dumps(dict(type="stopped",session=config["session"],reason="user_stop",transcription_complete=False)),flush=True)
    raise SystemExit(0)
signal.signal(signal.SIGINT,stopped)
ack=socket.socket(fileno=config["controlAckFD"])
ack.send(json.dumps(dict(type="recording_paused",session=config["session"],control_revision=1,capture_gate="closed",upload_gate="draining_saved_audio",draining_tracks=[])).encode())
ack.close()
while True: time.sleep(.02)
''')
            binary.chmod(0o700)
            config={'session':session,'cache_id':cache_id}
            read_fd,write_fd=os.pipe();open_stdin=os.fdopen(read_fd,'r')
            receipt_locked=threading.Event();release_receipt=threading.Event()
            original_write=gui_worker.write_control_receipt
            def blocked_write(path,receipt):
                if receipt.get('last_event')=='recording_paused' and not receipt_locked.is_set():
                    receipt_locked.set()
                    if not release_receipt.wait(2):
                        raise TimeoutError('test receipt lock release')
                original_write(path,receipt)
            def send_signal_when_locked():
                if receipt_locked.wait(3):
                    os.kill(os.getpid(),signal.SIGINT)
                    deadline=time.monotonic()+2
                    while time.monotonic()<deadline and not marker.exists():
                        time.sleep(.01)
                    release_receipt.set()
            sender=threading.Thread(target=send_signal_when_locked,daemon=True)
            sender.start()
            try:
                with patch.object(Path,'home',return_value=root), \
                     patch.object(gui_worker,'write_control_receipt',side_effect=blocked_write), \
                     patch.dict(os.environ,{'STOP_MARKER':str(marker)}), \
                     patch.object(gui_worker.sys,'stdin',open_stdin), \
                     contextlib.redirect_stdout(io.StringIO()):
                    gui_worker.run_independent_session(config,binary,cloud=False)
                self.assertTrue(marker.exists(),'watcher did not deliver queued signal stop')
                receipt=json.loads((cache/'recording-control.json').read_text())
                self.assertEqual(receipt['last_request']['source'],'signal')
                self.assertEqual(receipt['last_request']['action'],'stop')
            finally:
                release_receipt.set()
                os.close(write_fd)
                open_stdin.close()
                sender.join(timeout=2)

    def test_control_receipt_reason_rejects_unstructured_content(self):
        event={'type':'recording_control_failed','session':'s','reason':'secret key=abc and transcript'}
        snapshot=gui_worker.recording_control_snapshot(event,None,'s')
        self.assertNotIn('capture_failure_reason',snapshot)
        request=gui_worker.append_control_request(None,'s','pause',source='ui')
        self.assertEqual(request['last_request']['action'],'pause')
        self.assertNotIn('secret',json.dumps(request))

    def test_stale_wrong_session_or_unknown_tail_cannot_change_receipt(self):
        base = dict(schema=1, session='s', control_revision=4, pause_tracks={'mic': 'processing'})
        for event in [dict(type='recording_paused', session='other', control_revision=5),
                      dict(type='recording_paused', session='s', control_revision=3),
                      dict(type='recording_pause_tail', session='s', pause_revision=3, track='mic', state='complete'),
                      dict(type='recording_pause_tail', session='s', pause_revision=4, track='remote', state='complete')]:
            self.assertIsNone(gui_worker.recording_control_snapshot(event, base, 's'))
        self.assertEqual(base['pause_tracks'], {'mic': 'processing'})
