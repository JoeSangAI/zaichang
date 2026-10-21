import unittest,json,uuid
from identity_session import IdentitySession
from identity_bridge import PARTITION
class Workflow(unittest.TestCase):
    def setUp(self):self.s=IdentitySession('s',synthetic_only=True)
    def command(self,op,**fields):return self.s.command(dict(session='s',human_confirmed=True,command_id=str(uuid.uuid4()),operation=op,**fields))
    def event(self,p,i,slot=0):
        v=[0.0]*192;v[slot]=1
        return dict(type='segment',session='s',segment_id=f'{p}-{i}',revision=1,start=i*3,end=i*3+3,final=True,source_id='remote',epoch=p,speaker={'basis':'anonymous_cluster'},identity_features=dict(values=v,partition=PARTITION,input_kind='synthetic_model_output',source_id='remote',epoch=p,quality_gate='single_model_slot_asr_final_unclipped'))
    def populate(self):
        for p,slot in [('a',0),('b',1)]:
            self.command('person',person_id=p,name=p);self.command('consent',person_id=p,person_informed=True,ephemeral_use_allowed=True)
            for i in range(3):
                e=self.event(p,i,slot);self.s.observe(e);self.command('sample',person_id=p,segment_id=e['segment_id'],segment_revision=1)
    def test_complete_confirm_correct_undo_delete_and_restart(self):
        self.populate();self.command('calibrate');e=self.event('a',9);self.s.observe(e)
        candidates=self.s.observe(e);self.assertEqual(candidates[0]['person_id'],'a')
        self.command('feedback',segment_id=e['segment_id'],segment_revision=1,person_id='a',decision='confirmed');count=len(self.s.store.samples)
        self.command('feedback',segment_id=e['segment_id'],segment_revision=1,person_id='b',decision='corrected');self.assertEqual(self.s.manual[e['segment_id']],'b')
        self.command('undo');self.assertEqual(self.s.manual[e['segment_id']],'a');self.assertEqual(len(self.s.store.samples),count)
        restored=IdentitySession('new',synthetic_only=True,snapshot=self.s.snapshot());self.assertEqual(len(restored.store.samples),6)
        self.command('delete',person_id='a');self.command('undo');self.assertNotIn('a',self.s.people);self.assertTrue(all(x.person_id!='a' for x in self.s.store.samples.values()))
    def test_no_permission_bad_sample_and_stale_feedback(self):
        live=IdentitySession('s')
        with self.assertRaises(ValueError):live.command(dict(session='s',operation='person',person_id='a',name='a',human_confirmed=True,command_id='1'))
        self.command('person',person_id='a',name='a')
        e=self.event('a',0);self.s.observe(e)
        with self.assertRaises(ValueError):self.command('sample',person_id='a',segment_id=e['segment_id'],segment_revision=1)
        self.command('consent',person_id='a',person_informed=True,ephemeral_use_allowed=True)
        self.command('sample',person_id='a',segment_id=e['segment_id'],segment_revision=1)
        with self.assertRaises(ValueError):self.command('sample',person_id='a',segment_id=e['segment_id'],segment_revision=1)
        e['revision']=2;self.s.observe(e)
        with self.assertRaises(ValueError):self.command('feedback',segment_id=e['segment_id'],segment_revision=1,person_id='a',decision='confirmed')
    def test_not_enough_or_ambiguous_samples_keep_unknown(self):
        self.populate()
        for k,v in list(self.s.store.samples.items()):
            from dataclasses import replace
            self.s.store.samples[k]=replace(v,vector=(1.,)+(0.,)*191)
        with self.assertRaises(ValueError):self.command('calibrate')
        self.assertIsNone(self.s.calibration)
    def test_synthetic_archive_cannot_restore_live(self):
        self.populate()
        with self.assertRaises(ValueError):IdentitySession('s',human_use_authorized=True,snapshot=self.s.snapshot())
    def test_repeated_consent_preserves_samples_and_future_recovery(self):
        self.populate();before=self.s.consents['a']['consent_id']
        self.command('consent',person_id='a',person_informed=True,ephemeral_use_allowed=True)
        self.assertEqual(self.s.consents['a']['consent_id'],before)
        restored=IdentitySession('restart',synthetic_only=True,snapshot=self.s.snapshot())
        self.assertEqual(len(restored.store.samples),6)
    def test_invalid_archive_size_and_name_are_rejected(self):
        state=self.s.snapshot();state['people']={'a':'bad\nname'}
        with self.assertRaises(ValueError):IdentitySession('s',synthetic_only=True,snapshot=state)
        state=self.s.snapshot();state['manual']={str(i):'a' for i in range(201)}
        with self.assertRaises(ValueError):IdentitySession('s',synthetic_only=True,snapshot=state)

    def test_forget_all_purges_worker_state_and_cannot_undo(self):
        self.populate();self.command('forget_all');self.command('undo')
        self.assertFalse(self.s.people);self.assertFalse(self.s.store.samples);self.assertFalse(self.s.cache)
        restored=IdentitySession('restart',synthetic_only=True,snapshot=self.s.snapshot())
        self.assertFalse(restored.store.samples)
