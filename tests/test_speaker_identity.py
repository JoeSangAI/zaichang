import unittest
from speaker_identity import IdentityStore, Sample
class IdentityPolicyTests(unittest.TestCase):
    def setUp(self):self.store=IdentityStore()
    def sample(self,id='s',person='p',vector=(1.,0.),consent='consent',overlap=False):
        return Sample(id,person,vector,'fake-model',consent,'human-feedback',True,overlap)
    def test_only_confirmed_consented_good_sample(self):
        with self.assertRaises(ValueError):self.store.enroll(self.sample())
        with self.assertRaises(ValueError):self.store.enroll(self.sample(consent=''),human_confirmed=True)
        with self.assertRaises(ValueError):self.store.enroll(self.sample(overlap=True),human_confirmed=True)
        self.assertFalse(self.store.samples)
    def test_undo_and_revoke_cannot_resurrect(self):
        self.store.enroll(self.sample(),human_confirmed=True)
        self.store.enroll(self.sample(person='corrected'),human_confirmed=True)
        self.store.undo();self.assertEqual(self.store.samples['s'].person_id,'p')
        self.store.revoke('consent');self.store.undo();self.assertFalse(self.store.samples)
    def test_model_absent_and_version_mismatch(self):
        self.store.enroll(self.sample(),human_confirmed=True)
        args=dict(model_version='different',quality_ok=True,overlap=False,threshold=.9,margin=.1,calibration_version='fake-calibration')
        self.assertEqual(self.store.candidates((1,0),**args)['status'],'model_unavailable')
        self.store.model_available=True
        self.assertEqual(self.store.candidates((1,0),**args)['status'],'unknown')
    def test_candidate_never_enrolls_and_overlap_unknown(self):
        self.store.enroll(self.sample(),human_confirmed=True);self.store.model_available=True
        args=dict(model_version='fake-model',quality_ok=True,overlap=False,threshold=.9,margin=.1,calibration_version='fake-calibration')
        self.assertEqual(self.store.candidates((1,0),**args)['status'],'candidate_requires_confirmation')
        args['overlap']=True;self.assertEqual(self.store.candidates((1,0),**args)['status'],'unknown')
        self.assertEqual(len(self.store.samples),1)
    def test_ambiguous_match_unknown_and_delete_no_undo(self):
        self.store.enroll(self.sample(),human_confirmed=True);self.store.enroll(self.sample('s2','other'),human_confirmed=True);self.store.model_available=True
        args=dict(model_version='fake-model',quality_ok=True,overlap=False,threshold=.9,margin=.1,calibration_version='fake-calibration')
        self.assertEqual(self.store.candidates((1,0),**args)['status'],'unknown')
        self.store.forget_person('p');self.store.undo();self.assertTrue(all(s.person_id!='p' for s in self.store.samples.values()))
