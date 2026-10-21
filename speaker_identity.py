"""In-memory identity policy; no model, audio, persistence, or automatic enrollment.
source != cluster != person. Scores are cosine similarities, not probabilities.
"""
from dataclasses import dataclass, replace
import math

@dataclass(frozen=True)
class Sample:
    sample_id: str
    person_id: str
    vector: tuple
    model_version: str
    consent_id: str
    feedback_id: str
    quality_ok: bool
    overlap: bool = False

class IdentityStore:
    def __init__(self):
        self.samples = {}
        self.history = []
        self.revoked_consents = set()
        self.model_available = False

    def enroll(self, sample, *, human_confirmed=False):
        if not human_confirmed or not sample.consent_id or sample.consent_id in self.revoked_consents:
            raise ValueError('explicit confirmation and active consent required')
        if not sample.quality_ok or sample.overlap or not sample.person_id or not sample.feedback_id:
            raise ValueError('unreliable sample')
        vector=tuple(float(x) for x in sample.vector)
        if not vector or not all(math.isfinite(x) for x in vector) or not sum(x*x for x in vector):
            raise ValueError('invalid embedding')
        old=self.samples.get(sample.sample_id)
        self.history.append((sample.sample_id,old))
        self.samples[sample.sample_id]=replace(sample,vector=vector)

    def undo(self):
        if not self.history: return
        sample_id, old=self.history.pop()
        if old is None or old.consent_id in self.revoked_consents:
            self.samples.pop(sample_id,None)
        else: self.samples[sample_id]=old

    def revoke(self, consent_id):
        self.revoked_consents.add(consent_id)
        self.samples={k:v for k,v in self.samples.items() if v.consent_id!=consent_id}
        self.history=[(k,v) for k,v in self.history if v is None or v.consent_id!=consent_id]

    def forget_person(self, person_id):
        ids={k for k,v in self.samples.items() if v.person_id==person_id}
        self.samples={k:v for k,v in self.samples.items() if v.person_id!=person_id}
        self.history=[(k,v) for k,v in self.history if k not in ids and (v is None or v.person_id!=person_id)]

    def candidates(self, vector, *, model_version, quality_ok, overlap, threshold, margin, calibration_version):
        if not self.model_available: return {'status':'model_unavailable','candidates':[]}
        if not quality_ok or overlap or not calibration_version:
            return {'status':'unknown','candidates':[]}
        vector=tuple(float(x) for x in vector)
        if not vector or not all(math.isfinite(x) for x in vector) or not sum(x*x for x in vector):
            return {'status':'unknown','candidates':[]}
        if not -1<=threshold<=1 or not 0<=margin<=2: raise ValueError('invalid calibration')
        scores={}
        for sample in self.samples.values():
            if sample.model_version!=model_version or len(sample.vector)!=len(vector):continue
            score=sum(a*b for a,b in zip(vector,sample.vector))/(math.sqrt(sum(x*x for x in vector))*math.sqrt(sum(x*x for x in sample.vector)))
            scores[sample.person_id]=max(scores.get(sample.person_id,-1),score)
        ranked=sorted(scores.items(),key=lambda x:x[1],reverse=True)
        if not ranked or ranked[0][1]<threshold or len(ranked)>1 and ranked[0][1]-ranked[1][1]<margin:
            return {'status':'unknown','candidates':[]}
        return {'status':'candidate_requires_confirmation','candidates':[{'person_id':ranked[0][0],'cosine_similarity':ranked[0][1]}],
                'model_version':model_version,'calibration_version':calibration_version}
