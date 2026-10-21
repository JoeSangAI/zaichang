"""Offline complete identity workflow fixtures; fake identities only, no capture/network/keychain."""
import json, uuid, time
from pathlib import Path
from identity_session import IdentitySession
from identity_bridge import PARTITION
from fee_meter import FeeMeter

def simulate(folder, round_number):
    s=IdentitySession('fixture',synthetic_only=True);events=[];checks=0;recording=True
    def command(op,**kw):
        c=dict(session=s.session,human_confirmed=True,command_id=str(uuid.uuid4()),operation=op,**kw)
        out=s.command(c)
        if recording:events.extend(out)
        return c
    def event(p,i,slot=0,vector=None):
        v=vector or ([0.0]*slot+[1.0]+[0.0]*(191-slot))
        return dict(type='segment',session=s.session,segment_id=f'{p}-{i}',revision=1,start=i*3.,end=i*3.+3,final=True,text='合成流程 '+p,track='remote',source_id='remote',epoch=p,speaker={'basis':'anonymous_cluster','cluster_id':slot},identity_features=dict(values=v,partition=PARTITION,input_kind='synthetic_model_output',source_id='remote',epoch=p,quality_gate='single_model_slot_asr_final_unclipped'))
    for p,slot in [('a',0),('b',1)]:
        command('person',person_id=p,name='假人物'+p)
        command('consent',person_id=p,person_informed=True,ephemeral_use_allowed=True)
        for i in range(3):
            e=event(p,i,slot);events.append(e);events.extend(s.observe(e));command('sample',person_id=p,segment_id=e['segment_id'],segment_revision=1)
    command('calibrate');checks+=1
    probe=event('a',9);events.append(probe);events.extend(s.observe(probe));assert events[-1]['person_id']=='a';checks+=1
    command('feedback',segment_id=probe['segment_id'],segment_revision=1,person_id='a',decision='confirmed')
    command('feedback',segment_id=probe['segment_id'],segment_revision=1,person_id='b',decision='corrected');assert s.manual[probe['segment_id']]=='b';checks+=1
    command('undo');assert s.manual[probe['segment_id']]=='a';checks+=1
    command('feedback',segment_id=probe['segment_id'],segment_revision=1,person_id='a',decision='rejected');assert probe['segment_id'] not in s.manual;checks+=1
    command('undo');assert len(s.store.samples)==6;checks+=1
    snapshot=s.snapshot();restarted=IdentitySession('restart',synthetic_only=True,snapshot=snapshot);assert len(restarted.store.samples)==6;checks+=1
    replay=command('persistent_consent',person_id='a',person_informed=True,persistent_use_allowed=True)
    assert s.command(replay)[0]['replayed'];checks+=1
    # Actual previously verified CAM++ tone vector is allowed only in the synthetic domain.
    model=json.loads((folder.parent/'local-embedding-install/synthetic-run.json').read_text())
    vector=model.get('vector',model.get('embedding'))
    assert isinstance(vector,list) and len(vector)==192
    actual=event('actual-tone',1,vector=vector);s.observe(actual)
    command('person',person_id='tone',name='合成音调非真人');command('consent',person_id='tone',person_informed=True,ephemeral_use_allowed=True)
    command('sample',person_id='tone',segment_id=actual['segment_id'],segment_revision=1);assert len(s.store.samples)==7;checks+=1
    # Long virtual meeting exercises bounded cache and feedback, no audio or real clock wait.
    recording=False;start=time.monotonic()
    for i in range(18000):
        e=event('stress',i,i%2);s.observe(e)
        if i%10==0:command('feedback',segment_id=e['segment_id'],segment_revision=1,person_id='a',decision='confirmed')
    assert len(s.cache)==200 and len(s.feedback)<=200 and len(s.manual)<=200 and len(s.receipts)==128 and len(s.journal)<=8;checks+=1
    # Do not send 1800 feedback history events to native UI: native pressure has its own path.
    events=events[:next(i for i,e in enumerate(events) if e.get('operation')=='person' and e.get('person_id')=='tone')]
    saved=s.snapshot();command('revoke',person_id='a');command('undo');assert all(x.person_id!='a' for x in s.store.samples.values());checks+=1
    command('delete',person_id='b');assert 'b' not in s.people;checks+=1
    live=IdentitySession('real',human_use_authorized=True)
    try:live.restore(saved);raise AssertionError('synthetic entered live')
    except ValueError:checks+=1
    meter=FeeMeter()
    for x in [3,6,9]:meter.observe(dict(type='usage_provider',track='remote',task_id='r',duration=x,final=x==9))
    meter.observe(dict(type='stopped',received_at=10.,recording_elapsed_seconds=10.))
    assert meter.snapshot()['input_audio_seconds']=='9' and meter.snapshot()['elapsed_seconds']==10.;checks+=1
    folder.mkdir(exist_ok=True,parents=True)
    fixture={'events':events,'archive_state':snapshot,'purged_state':s.snapshot(),'checks':checks,'stress_virtual_seconds':1800,'stress_events':18000,'identity_stress_wall_seconds':time.monotonic()-start,'real_cam_tone_vector_consumed':True,'positive_matching_uses_fake_basis_vectors':True,'capture':False,'network':False,'keychain':False,'round':round_number}
    (folder/f'round-{round_number}.json').write_text(json.dumps(fixture,ensure_ascii=False))
    return {k:v for k,v in fixture.items() if k not in ('events','archive_state','purged_state')}

if __name__=='__main__':
    root=Path(__file__).resolve().parents[1]/'native/validation-workflow'
    print(json.dumps([simulate(root,i) for i in (1,2)],ensure_ascii=False))
