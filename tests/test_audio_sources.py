import json
import signal
import tempfile
import unittest
from pathlib import Path
from audio_sources import is_transcript_track, transcript_tracks, recording_control_signal
from fee_meter import FeeMeter
from gui_worker import capture_status_event

class SourceContracts(unittest.TestCase):
    def test_dynamic_stream_budget_counts_all_apps_and_excludes_reference(self):
        meter=FeeMeter();a='app-0123456789abcdef';b='app-fedcba9876543210'
        meter.observe({'type':'health','elapsed_seconds':3,a:{'task_id':'a','sent_audio_seconds':2},b:{'task_id':'b','sent_audio_seconds':3},'mic':{'task_id':'m','sent_audio_seconds':1},'reference':{'sent_audio_seconds':8},'mic-raw':{'sent_audio_seconds':8}})
        self.assertEqual(meter.snapshot()['input_audio_seconds'],'6')
        meter.observe({'type':'usage_local','track':a,'task_id':'retry','sent_audio_seconds':2})
        self.assertEqual(meter.snapshot()['input_audio_seconds'],'8')
        with self.assertRaises(ValueError):meter.bind('reference','r')
    def test_control_bound_to_actual_meeting_and_explicit_action(self):
        command={'operation':'recording_control','action':'pause','session':'s'}
        self.assertEqual(recording_control_signal(command,'s'),signal.SIGUSR1)
        self.assertIsNone(recording_control_signal(command,'other'))
        self.assertIsNone(recording_control_signal(dict(command,action='stop'),'s'))
        self.assertEqual(recording_control_signal(dict(command,action='resume'),'s'),signal.SIGUSR2)
        self.assertEqual(recording_control_signal(dict(command,action='finish'),'s'),signal.SIGWINCH)
    def test_manifests_never_promote_raw_or_unsafe_source_to_cloud(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            for name in ['mic','app-0123456789abcdef','reference','mic-raw','app-ABCDEF0123456789','random']:
                (root/(name+'-manifest.json')).write_text('{}')
            self.assertEqual(transcript_tracks(root),['app-0123456789abcdef','mic'])
        for value in [None,True,'../mic','app-short','reference','mic-raw']:
            self.assertFalse(is_transcript_track(value))
    def test_generations_are_strict_and_share_accounting(self):
        for track in ['remote-g1','remote-g999','app-0123456789abcdef-g1','app-0123456789abcdef-g999']:
            self.assertTrue(is_transcript_track(track))
        for track in ['remote-g0','remote-g01','remote-g1000','remote-g1\n','app-0123456789abcdef-g0','app-0123456789abcdef-g01','app-0123456789abcdef-g1000']:
            self.assertFalse(is_transcript_track(track))
        meter=FeeMeter()
        meter.observe({'type':'usage_local','track':'remote-g1','task_id':'old','sent_audio_seconds':1})
        meter.observe({'type':'usage_local','track':'remote-g2','task_id':'new','sent_audio_seconds':1})
        self.assertEqual(meter.snapshot()['input_audio_seconds'],'2')

    def test_source_activity_does_not_expose_internal_reference(self):
        app='app-0123456789abcdef'
        event=capture_status_event({'type':'health','session':'s',app:{'pcm_bytes':2,'secret':'hidden'},'reference':{'pcm_bytes':8},'mic-raw':{'pcm_bytes':4}})
        self.assertEqual(event,{'type':'capture_status','session':'s','tracks':{app:2}})

if __name__=='__main__':unittest.main()
