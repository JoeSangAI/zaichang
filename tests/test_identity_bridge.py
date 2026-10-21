import unittest
from identity_bridge import IdentityPolicyBridge,PARTITION
class IdentityGate(unittest.TestCase):
    def event(self):
        return {'source_id':'remote','epoch':'e','final':True,'speaker':{'basis':'anonymous_cluster'},'identity_features':{'values':[1.0]+[0.0]*191,'partition':PARTITION,'input_kind':'synthetic_model_output','source_id':'remote','epoch':'e','quality_gate':'single_model_slot_asr_final_unclipped'}}
    def test_synthetic_is_not_live(self):
        self.assertEqual(IdentityPolicyBridge().process(self.event())['reason'],'partition_or_input_domain')
    def test_no_calibration_no_person(self):
        self.assertEqual(IdentityPolicyBridge(synthetic_only=True).process(self.event())['reason'],'uncalibrated')
    def test_dimension_quality_and_epoch_rejected(self):
        b=IdentityPolicyBridge(synthetic_only=True)
        for key,value,reason in [('values',[1.0],'invalid_vector'),('epoch','wrong','partition_or_input_domain')]:
            e=self.event();e['identity_features'][key]=value;self.assertEqual(b.process(e)['reason'],reason)
        e=self.event();e['speaker']['basis']='multiple';self.assertEqual(b.process(e)['reason'],'unreliable_segment')
