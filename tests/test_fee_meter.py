import unittest
from decimal import Decimal
from fee_meter import (FeeMeter, recorded_session_fee, session_usage_snapshot,
                       coarse_reserved_yuan, cumulative_asr_fee, combined_session_fee)
class MeterContract(unittest.TestCase):
    def test_asr_and_coarse_costs_remain_estimates_without_enforcement(self):
        from pathlib import Path
        import json, tempfile
        with tempfile.TemporaryDirectory() as folder:
            directory=Path(folder)
            usage=session_usage_snapshot(dict(input_audio_seconds='1000',estimated_yuan='0.33'),0,Decimal(0),'session-a')
            (directory/'coarse-audio-progress.json').write_text(json.dumps({
                'schema':1,'session':'session-a','cache_id':'cache-a','budget_yuan':1,
                'reserved_yuan':'0.42','segments':{'one':{'status':'reserved_unknown','reserved_yuan':'0.42'}}
            }))
            self.assertEqual(cumulative_asr_fee(usage),Decimal('0.33'))
            self.assertEqual(coarse_reserved_yuan(directory,'session-a'),Decimal('0.42'))
            self.assertEqual(combined_session_fee(usage,directory,'session-a'),Decimal('0.75'))
            self.assertEqual(usage['cumulative_estimated_yuan'],'0.33')

    def test_missing_coarse_ledger_is_zero_and_invalid_ledger_is_unknown(self):
        from pathlib import Path
        import json, tempfile
        with tempfile.TemporaryDirectory() as folder:
            directory=Path(folder)
            self.assertEqual(coarse_reserved_yuan(directory,'s'),Decimal(0))
            ledger=directory/'coarse-audio-progress.json'
            for invalid in [
                {'schema':1,'session':'other','reserved_yuan':'0.1'},
                {'schema':1,'session':'s','reserved_yuan':'NaN'},
                {'schema':1,'session':'s','reserved_yuan':'NaN'},
                {'schema':1,'session':'s','reserved_yuan':True},
            ]:
                ledger.write_text(json.dumps(invalid))
                with self.subTest(invalid=invalid):self.assertIsNone(coarse_reserved_yuan(directory,'s'))
            ledger.write_text('{broken')
            self.assertIsNone(coarse_reserved_yuan(directory,'s'))

    def test_legacy_usage_reconstructs_estimate_and_corruption_is_unknown(self):
        legacy={'cumulative_input_audio_seconds':1000,'meter':{'input_audio_seconds':'100','estimated_yuan':'0.033'}}
        self.assertEqual(cumulative_asr_fee(legacy),Decimal('0.33000'))
        self.assertIsNone(cumulative_asr_fee({'schema':2,'cumulative_estimated_yuan':None}))
        self.assertIsNone(cumulative_asr_fee(None))
        self.assertIsNone(combined_session_fee({'schema':2,'cumulative_estimated_yuan':None},'.','fixture'))

    def test_session_cost_survives_multiple_recoveries(self):
        snapshot=dict(input_audio_seconds='100',estimated_yuan='0.033')
        first=session_usage_snapshot(snapshot,0,Decimal(0),'fixture')
        self.assertNotIn('cloud_budget_yuan',first);self.assertNotIn('audio_ceiling_seconds',first)
        second=session_usage_snapshot(snapshot,100,recorded_session_fee(first),'fixture')
        third=session_usage_snapshot(snapshot,200,recorded_session_fee(second),'fixture')
        self.assertEqual(recorded_session_fee(third),Decimal('0.099'))
        self.assertEqual(third['cumulative_input_audio_seconds'],300)

    def test_legacy_partial_or_missing_cost_stays_unknown(self):
        old=dict(schema=1,cumulative_input_audio_seconds=200,meter=dict(input_audio_seconds='100',estimated_yuan='0.033'))
        self.assertIsNone(recorded_session_fee(old))
        old['cumulative_input_audio_seconds']=100
        self.assertEqual(recorded_session_fee(old),Decimal('0.033'))
        unknown=session_usage_snapshot(old['meter'],200,None,'fixture')
        self.assertIsNone(recorded_session_fee(unknown))
        self.assertIsNone(recorded_session_fee({}))
        for invalid in [True,'NaN','Infinity',-1]:
            self.assertIsNone(recorded_session_fee(dict(schema=2,cumulative_estimated_yuan=invalid)))

    def test_reconnect_task_attempts_do_not_double_count_track_total(self):
        m=FeeMeter()
        m.observe({'type':'health','elapsed_seconds':2,'mic':{'task_id':'a','sent_audio_seconds':2,'task_attempted_audio_seconds':2}})
        m.observe({'type':'usage_local','track':'mic','task_id':'a','sent_audio_seconds':2})
        m.observe({'type':'health','elapsed_seconds':3,'mic':{'task_id':'b','sent_audio_seconds':3,'task_attempted_audio_seconds':1}})
        self.assertEqual(m.snapshot()['input_audio_seconds'],'3')

    def test_cumulative_usage_not_summed(self):
        m=FeeMeter()
        for value in [3,6,9,9,6]:m.observe({'type':'usage_provider','track':'mic','task_id':'a','duration':value,'final':False})
        self.assertEqual(Decimal(m.snapshot()['estimated_yuan']),Decimal('9')*Decimal('0.00033'))
    def test_two_tracks_wall_clock_separate_and_silence_charged(self):
        m=FeeMeter();m.observe({'type':'health','elapsed_seconds':60,'mic':{'task_id':'a','sent_audio_seconds':58},'remote':{'task_id':'b','sent_audio_seconds':60}})
        self.assertEqual(m.snapshot()['elapsed_seconds'],60)
        self.assertEqual(Decimal(m.snapshot()['estimated_yuan']),Decimal('118')*Decimal('0.00033'))
        self.assertEqual(m.snapshot()['balance_status'],'not_connected')
    def test_local_provider_not_added_final_calibration(self):
        m=FeeMeter();m.observe({'type':'usage_local','track':'mic','sent_audio_seconds':9.2})
        m.observe({'type':'usage_provider','track':'mic','task_id':'a','duration':9,'final':False})
        self.assertEqual(Decimal(m.snapshot()['input_audio_seconds']),Decimal('9.2'))
        m.observe({'type':'usage_provider','track':'mic','task_id':'a','duration':10,'final':True})
        self.assertEqual(Decimal(m.snapshot()['input_audio_seconds']),Decimal(10))
        self.assertEqual(m.snapshot()['basis'],'service_usage')
        self.assertFalse(m.snapshot()['supplier_bill_verified'])
    def test_reconnect_tasks_counted_independently(self):
        m=FeeMeter()
        m.observe({'type':'usage_provider','track':'remote','task_id':'one','duration':8,'final':True})
        m.observe({'type':'usage_provider','track':'remote','task_id':'two','duration':4,'final':True})
        self.assertEqual(Decimal(m.snapshot()['input_audio_seconds']),Decimal(12))
    def test_stop_freezes_capture_time_not_final_drain_time(self):
        m=FeeMeter()
        m.observe({'type':'health','elapsed_seconds':5,'mic':{'sent_audio_seconds':5},'remote':{'sent_audio_seconds':5}})
        m.observe({'type':'stopped','received_at':6.5,'recording_elapsed_seconds':5.1})
        self.assertAlmostEqual(m.snapshot()['elapsed_seconds'],5.1)
        self.assertEqual(Decimal(m.snapshot()['input_audio_seconds']),Decimal(10))

    def test_invalid_nan_cross_track_rejected(self):
        m=FeeMeter()
        for value in [-1,float('nan'),float('inf'),True,'99']:
            with self.assertRaises(ValueError):m.observe({'type':'usage_provider','track':'mic','task_id':'a','duration':value})
        m.observe({'type':'usage_provider','track':'mic','task_id':'a','duration':1})
        with self.assertRaises(ValueError):m.observe({'type':'usage_provider','track':'remote','task_id':'a','duration':1})
if __name__=='__main__':unittest.main()
