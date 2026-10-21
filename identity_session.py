"""Local session identity workflow. No file/network I/O, automatic learning, or credential lookup."""
import json,math,uuid,threading
from dataclasses import asdict
from identity_bridge import IdentityPolicyBridge,PARTITION
from speaker_identity import IdentityStore,Sample

def cosine(a,b):return sum(x*y for x,y in zip(a,b))/(math.sqrt(sum(x*x for x in a))*math.sqrt(sum(x*x for x in b)))
def token(v):
    if not isinstance(v,str) or not v or len(v)>160 or any(ord(x)<32 for x in v):raise ValueError('invalid_id')
    return v
class IdentitySession:
    def __init__(self,session,*,synthetic_only=False,human_use_authorized=False,snapshot=None):
        self.session=token(session);self.synthetic_only=synthetic_only;self.human_use_authorized=human_use_authorized
        self.people={};self.consents={};self.store=IdentityStore();self.calibration=None;self.feedback={};self.manual={};self.journal=[];self.cache={};self.sample_sources={};self.receipts={};self.lock=threading.RLock()
        if snapshot:self.restore(snapshot)
    @property
    def input_kind(self):return 'synthetic_model_output' if self.synthetic_only else 'consented_live_audio'
    def _policy(self):return IdentityPolicyBridge(self.store,synthetic_only=self.synthetic_only,calibration=self.calibration)
    def observe(self,event):
        with self.lock:
            if event.get('type')!='segment':return []
            if event.get('session')!=self.session:raise ValueError('identity_session_mismatch')
            sid=token(event.get('segment_id'));self.cache[sid]=json.loads(json.dumps(event))
            while len(self.cache)>200:self.cache.pop(next(iter(self.cache)))
            result=self._policy().process(event) if self.synthetic_only or self.human_use_authorized else {'status':'unknown','reason':'human_identity_scope_not_authorized'};out=[]
            if result['status']=='candidate_requires_confirmation':
                person=result['candidates'][0]['person_id']
                if person in self.people and self._active(person):out.append({'type':'identity_candidate','session':self.session,'segment_id':sid,'segment_revision':event['revision'],'source_id':event.get('source_id'),'epoch':event.get('epoch'),'person_id':person,'cosine_similarity':result['candidates'][0]['cosine_similarity'],'calibration_version':result['calibration_version'],'quality_ok':True,'overlap':False})
            elif sid not in self.manual:out.append({'type':'identity_status','session':self.session,'segment_id':sid,'status':'unknown','reason':result.get('reason','ambiguous_or_below_threshold')})
            return out
    def _active(self,p):return p in self.consents and self.consents[p]['active'] and self.consents[p]['consent_id'] not in self.store.revoked_consents
    def _remember(self,operation):
        self.journal.append({'operation':operation,'state':self.snapshot(include_journal=False)})
        if len(self.journal)>8:self.journal.pop(0)
    def _invalidate(self):self.calibration=None
    def command(self,c):
        with self.lock:
            if c.get('session')!=self.session or c.get('human_confirmed') is not True:raise ValueError('explicit_human_command_required')
            command_id=token(c.get('command_id'));op=c.get('operation')
            if command_id in self.receipts:return [dict(self.receipts[command_id],replayed=True)]
            if op not in {'person','consent','persistent_consent','sample','calibrate','feedback','clear_feedback','undo','revoke','delete','forget_all'}:raise ValueError('unsupported_identity_operation')
            if not self.synthetic_only and not self.human_use_authorized:raise ValueError('human_identity_scope_not_authorized')
            # Validate before mutation; command failures cannot add journal or partial state.
            before=self.snapshot()
            try:
                result=self._command(op,c)
            except Exception:
                self.restore(before);raise
            ack={'type':'identity_ack','session':self.session,'command_id':command_id,'operation':op,**result};self.receipts[command_id]=ack
            while len(self.receipts)>128:self.receipts.pop(next(iter(self.receipts)))
            return [ack,{'type':'identity_state','session':self.session,'state':self.snapshot()}]
    def _command(self,op,c):
        if op=='forget_all':
            for consent in self.consents.values():self.store.revoke(consent['consent_id'])
            self.people={};self.consents={};self.store.samples={};self.store.history=[];self.calibration=None;self.feedback={};self.manual={};self.journal=[];self.cache={};self.sample_sources={};self.receipts={}
            return {'not_undoable':True,'all_identity_forgotten':True}
        if op in {'person','consent','persistent_consent','revoke','delete'}:
            person=token(c.get('person_id'))
            if op=='person':
                name=c.get('name','').strip()
                if not isinstance(name,str) or not name or len(name)>80 or len(self.people)>=12 and person not in self.people:raise ValueError('invalid_person_name')
                self._remember(op);self.people[person]=name;return {'person_id':person}
            if person not in self.people:raise ValueError('unknown_person')
            if op=='consent':
                if c.get('person_informed') is not True or c.get('ephemeral_use_allowed') is not True:raise ValueError('person_consent_required')
                if self._active(person):return {'person_id':person,'consent_unchanged':True}
                self._remember(op);self.consents[person]={'consent_id':str(uuid.uuid4()),'active':True,'purpose':'local_identity_until_app_exit','persistent_allowed':False};return {'person_id':person}
            if op=='persistent_consent':
                if not self._active(person) or c.get('person_informed') is not True or c.get('persistent_use_allowed') is not True:raise ValueError('persistent_person_consent_required')
                self._remember(op);self.consents[person]['persistent_allowed']=True;self.consents[person]['purpose']='local_cross_meeting_identity';return {'person_id':person}
            # Destructive privacy actions purge history instead of being undoable.
            if self._active(person):self.store.revoke(self.consents[person]['consent_id'])
            self.store.forget_person(person);self.sample_sources={k:v for k,v in self.sample_sources.items() if k in self.store.samples};self.consents.pop(person,None)
            self.feedback={k:v for k,v in self.feedback.items() if v.get('person_id')!=person};self.manual={k:v for k,v in self.manual.items() if v!=person};self.journal=[];self._invalidate()
            if op=='delete':self.people.pop(person,None)
            return {'person_id':person,'not_undoable':True}
        if op=='sample':
            person=token(c.get('person_id'));sid=token(c.get('segment_id'));event=self.cache.get(sid)
            if not self._active(person):raise ValueError('person_consent_required')
            if not event or c.get('segment_revision')!=event.get('revision'):raise ValueError('segment_changed_or_unavailable')
            if event.get('speaker',{}).get('basis')!='anonymous_cluster':raise ValueError('single_speaker_sample_required')
            probe=IdentityPolicyBridge(synthetic_only=self.synthetic_only).process(event)
            if probe.get('reason')!='uncalibrated':raise ValueError('unreliable_or_wrong_domain_sample')
            if len(self.store.samples)>=60:raise ValueError('sample_capacity')
            f=event['identity_features'];source=(event.get('source_id'),event.get('epoch'),event.get('start'),event.get('end'))
            if list(source) in self.sample_sources.values():raise ValueError('duplicate_audio_sample')
            sample_id=str(uuid.uuid4());self._remember(op)
            self.store.enroll(Sample(sample_id,person,tuple(f['values']),PARTITION,self.consents[person]['consent_id'],token(c.get('command_id')),True),human_confirmed=True);self.sample_sources[sample_id]=list(source);self._invalidate()
            return {'sample_id':sample_id,'person_id':person,'sample_count':len(self.store.samples)}
        if op=='calibrate':
            groups={p:[s for s in self.store.samples.values() if s.person_id==p] for p in self.people if self._active(p)};groups={p:s for p,s in groups.items() if len(s)>=3}
            if len(groups)<2:raise ValueError('need_two_people_three_independent_samples_each')
            train={p:s[:-1] for p,s in groups.items()};within=[cosine(a.vector,b.vector) for samples in train.values() for i,a in enumerate(samples) for b in samples[i+1:]]
            between=[cosine(a.vector,b.vector) for i,p in enumerate(train) for q in list(train)[i+1:] for a in train[p] for b in train[q]]
            low=min(within);high=max(between)
            if not low>high+0.02:raise ValueError('samples_not_separable_keep_unknown')
            threshold=(low+high)/2;margin=min(0.1,(low-high)/3)
            for p,samples in groups.items():
                held=samples[-1].vector;own=max(cosine(held,s.vector) for s in train[p]);other=max(cosine(held,s.vector) for q in train if q!=p for s in train[q])
                if own<threshold or own-other<margin:raise ValueError('held_out_sample_failed_keep_unknown')
            self._remember(op);self.calibration={'partition':PARTITION,'input_kind':self.input_kind,'threshold':threshold,'margin':margin,'version':str(uuid.uuid4()),'basis':'small_local_labeled_samples_with_held_out_checks','people_count':len(groups),'accuracy_claim':False}
            return {'calibration':self.calibration}
        if op=='clear_feedback':
            sid=token(c.get('segment_id'));self._remember(op);self.manual.pop(sid,None);self.feedback={k:v for k,v in self.feedback.items() if v['segment_id']!=sid};return {'segment_id':sid}
        if op=='feedback':
            sid=token(c.get('segment_id'));event=self.cache.get(sid)
            if not event or c.get('segment_revision')!=event.get('revision'):raise ValueError('segment_changed_or_unavailable')
            decision=c.get('decision');person=c.get('person_id')
            if decision not in {'confirmed','corrected','rejected'}:raise ValueError('invalid_feedback')
            if decision!='rejected' and (person not in self.people or not self._active(person)):raise ValueError('person_consent_required')
            self._remember(op);fid=token(c.get('command_id'));self.feedback[fid]={'segment_id':sid,'person_id':person,'decision':decision,'segment_revision':event['revision'],'source_id':event.get('source_id'),'epoch':event.get('epoch')}
            while len(self.feedback)>200:self.feedback.pop(next(iter(self.feedback)))
            if decision=='rejected':self.manual.pop(sid,None)
            else:self.manual[sid]=person
            while len(self.manual)>200:self.manual.pop(next(iter(self.manual)))
            # Feedback never adds samples. Learning requires the separate sample command.
            return {'segment_id':sid,'decision':decision,'person_id':person,'feedback_id':fid,'sample_count':len(self.store.samples)}
        if op=='undo':
            if not self.journal:return {'empty':True}
            entry=self.journal.pop();remaining=list(self.journal);receipts=dict(self.receipts);revoked=set(self.store.revoked_consents);self.restore(entry['state']);self.receipts.update(receipts);self.journal=remaining;self.store.revoked_consents|=revoked
            self.store.samples={k:s for k,s in self.store.samples.items() if s.consent_id not in revoked}
            return {'undone':entry['operation']}
    def snapshot(self,include_journal=True):
        result={'schema':1,'partition':PARTITION,'input_kind':self.input_kind,'people':dict(self.people),'consents':dict(self.consents),'samples':[asdict(s) for s in self.store.samples.values()],'receipts':dict(self.receipts),'sample_sources':dict(self.sample_sources),'revoked_consents':sorted(self.store.revoked_consents),'calibration':self.calibration,'feedback':dict(self.feedback),'manual':dict(self.manual)}
        if include_journal:result['journal']=self.journal
        return json.loads(json.dumps(result))
    def restore(self,state):
        if not isinstance(state,dict) or state.get('schema')!=1 or state.get('partition')!=PARTITION or state.get('input_kind')!=self.input_kind:raise ValueError('archive_domain_or_version')
        if not self.synthetic_only and not self.human_use_authorized and state.get('samples'):raise ValueError('human_identity_scope_not_authorized')
        people=state.get('people',{});consents=state.get('consents',{});samples=state.get('samples',[])
        if not isinstance(people,dict) or not isinstance(consents,dict) or not isinstance(samples,list) or len(people)>12 or len(samples)>60:raise ValueError('archive_capacity')
        for p,n in people.items():
            token(p)
            if not isinstance(n,str) or not n.strip() or len(n)>80 or any(ord(x)<32 for x in n):raise ValueError('archive_person_invalid')
        for key,limit in [('manual',200),('feedback',200),('receipts',128),('journal',8),('sample_sources',60)]:
            value=state.get(key,[] if key=='journal' else {})
            if not isinstance(value,list if key=='journal' else dict) or len(value)>limit:raise ValueError('archive_capacity')
        store=IdentityStore();store.revoked_consents=set(state.get('revoked_consents',[]))
        for item in samples:
            s=Sample(**item)
            if s.person_id not in people or s.model_version!=PARTITION or len(s.vector)!=192 or not consents.get(s.person_id,{}).get('active') or s.consent_id!=consents[s.person_id]['consent_id']:raise ValueError('archive_sample_consent_or_partition')
            if any(type(x) not in (int,float) or not math.isfinite(x) for x in s.vector) or abs(sum(x*x for x in s.vector)-1)>0.001:raise ValueError('archive_vector_invalid')
            store.enroll(s,human_confirmed=True)
        store.history=[];self.people=dict(people);self.consents=dict(consents);self.store=store;self.calibration=state.get('calibration');self.feedback=dict(state.get('feedback',{}));self.manual=dict(state.get('manual',{}));self.receipts=dict(state.get('receipts',{}));self.sample_sources=dict(state.get('sample_sources',{}));self.journal=list(state.get('journal',[]))[-8:]
