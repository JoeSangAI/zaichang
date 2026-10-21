"""Ephemeral embedding-to-policy bridge. No enrollment, HTTP, file writes or credential lookup."""
import math
from speaker_identity import IdentityStore
PARTITION='campplus:f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11:192'
class IdentityPolicyBridge:
    def __init__(self,store=None,*,synthetic_only=False,calibration=None):
        self.store=store or IdentityStore();self.store.model_available=True
        self.synthetic_only=synthetic_only;self.calibration=calibration
    def process(self,event):
        f=event.get('identity_features');speaker=event.get('speaker',{})
        if not isinstance(f,dict):return {'status':'unknown','reason':'no_eligible_features','candidates':[]}
        kind='synthetic_model_output' if self.synthetic_only else 'consented_live_audio'
        if f.get('partition')!=PARTITION or f.get('input_kind')!=kind or f.get('source_id')!=event.get('source_id') or f.get('epoch')!=event.get('epoch'):
            return {'status':'unknown','reason':'partition_or_input_domain','candidates':[]}
        if speaker.get('basis')!='anonymous_cluster' or event.get('final') is not True or event.get('quality_flags') or f.get('quality_gate')!='single_model_slot_asr_final_unclipped':
            return {'status':'unknown','reason':'unreliable_segment','candidates':[]}
        v=f.get('values')
        if not isinstance(v,list) or len(v)!=192 or any(type(x) not in (int,float) or not math.isfinite(x) for x in v) or abs(sum(x*x for x in v)-1)>0.001:
            return {'status':'unknown','reason':'invalid_vector','candidates':[]}
        if not self.calibration:return {'status':'unknown','reason':'uncalibrated','candidates':[]}
        c=self.calibration
        if c.get('partition')!=PARTITION or c.get('input_kind')!=kind:return {'status':'unknown','reason':'calibration_domain','candidates':[]}
        if not all(type(c.get(k)) in (int,float) and math.isfinite(c[k]) for k in ('threshold','margin')):return {'status':'unknown','reason':'invalid_calibration','candidates':[]}
        return self.store.candidates(v,model_version=PARTITION,quality_ok=True,overlap=False,threshold=c['threshold'],margin=c['margin'],calibration_version=c.get('version'))
