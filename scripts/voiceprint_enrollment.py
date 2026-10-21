"""Explicit local enrollment from a stopped, manually named meeting.

No capture, cloud, credentials or transcript edits. Writes only the requested
feature archive. Saved words supply time ranges, never inferred identities.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import tempfile
import uuid
from scripts.speaker_reconciliation import LocalExtractor, latest_events, key_token, sha, MODEL_SHA
PARTITION = 'campplus:' + MODEL_SHA + ':192'


def build_archive(directory, roster_names, root, *, confirmed=False):
    if not confirmed: raise ValueError('Explicit local cross-meeting use required')
    import numpy as np
    directory = Path(directory)
    if directory.is_symlink(): raise ValueError('Unsafe cache')
    metadata = json.loads((directory/'meeting.json').read_text())
    names = json.loads((directory/'session-names.json').read_text())
    if names['session'] != metadata['session']: raise ValueError('Wrong session')
    roster = []
    for name in roster_names:
        matches = [p for p in names['speakers'] if p['name'] == name]
        if len(matches) != 1: raise ValueError('Ambiguous named person')
        roster.append(matches[0])
    if not 2 <= len(roster) <= 12 or len(set(roster_names)) != len(roster_names): raise ValueError('Invalid roster')
    events, hashes = latest_events(directory)
    units = [(e, r) for e in events if e.get('final') and e.get('end_time_known') and not e.get('quality_flags')
             for r in e.get('speaker_runs') or [e]]
    audio, offsets = {}, {}
    origin=metadata.get("capture_origin_uptime",min(json.loads((directory/(t+"-manifest.json")).read_text())["origin_uptime"] for t in {p["key"]["source"] for p in roster}))
    for track in sorted({p['key']['source'] for p in roster}):
        mpath = directory/(track+'-manifest.json');m = json.loads(mpath.read_text())
        if m['track'] != track or not m.get('ended') or m.get('error') or m['written_bytes']>512*1024*1024: raise ValueError('Stopped complete recording required')
        chunks = []
        for c in m['chunks']:
            path = directory/f'{track}-{c["index"]:06}.pcm'
            if path.is_symlink(): raise ValueError('Unsafe audio')
            chunks.append(path.read_bytes())
        data = b''.join(chunks)
        if len(data) != m['written_bytes']: raise ValueError('Incomplete audio')
        audio[track] = np.frombuffer(data, dtype='<i2')
        offsets[track] = m['origin_uptime']-origin;hashes[mpath.name]=sha(mpath)
    hashes['session-names.json']=sha(directory/'session-names.json')
    extractor=LocalExtractor(root);people=[];heldout=[]
    def rank(vector, profiles):
        scores=[]
        for p in profiles:
            values=sorted((float(np.dot(vector,s['vector'])) for s in p['samples']),reverse=True)
            scores.append((p['name'],sum(values[:2])/2))
        return sorted(scores,key=lambda x:x[1],reverse=True)
    try:
        for person in roster:
            k=person['key'];slot=int(k['identity'].split(':')[1]);track=k['source']
            eligible=[(e,r) for e,r in units if e['source_id']==track and e['epoch']==k['epoch']
                      and r['speaker'].get('basis')=='anonymous_cluster' and r['speaker'].get('cluster_id')==slot
                      and r['end']-r['start']>=3]
            selected=eligible[::max(1,len(eligible)//16)][:16]
            samples=[]
            for e,r in selected:
                lo=r['start']+.2;hi=lo+2
                if any(s['start']<hi and s['end']>lo for s in samples):continue
                vector=extractor.extract(audio[track][round((lo-offsets[track])*16000):round((hi-offsets[track])*16000)])
                if vector is None:continue
                samples.append(dict(session=metadata['session'],source=track,epoch=k['epoch'],start=lo,end=hi,vector=[float(x) for x in vector]))
            if len(samples)<8: raise ValueError('Need eight independent clear named examples')
            # Independent held-out audio is never enrolled; prevent self matching.
            training=samples[::2][:8];probes=samples[1::2]
            people.append(dict(id=str(uuid.uuid4()),name=person['name'],authorizedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z'),enabled=True,samples=training))
            heldout.extend((person['name'],s) for s in probes)
        checks=[]
        for expected,sample in heldout:
            ranking=rank(sample['vector'],people)
            accepted=ranking[0][1]>=.60 and ranking[0][1]-ranking[1][1]>=.14
            if accepted and ranking[0][0]!=expected: raise ValueError('Held-out voice falsely matched another person')
            checks.append(dict(expected=expected,predicted=ranking[0][0] if accepted else None,score=round(ranking[0][1],4),margin=round(ranking[0][1]-ranking[1][1],4),start=sample['start']))
        for person in people:
            if sum(c['expected']==person['name'] and c['predicted']==person['name'] for c in checks)<3:raise ValueError('Not enough independent matches for '+person['name'])
        if any(sha(directory/name)!=value for name,value in hashes.items()):raise ValueError('Recording changed during enrollment')
        archive=dict(schema=1,partition=PARTITION,inputKind='consented_live_audio',revision=1,people=people)
        report=dict(source_cache=directory.name,source_sha256=hashes,training_samples={p['name']:len(p['samples']) for p in people},held_out=checks,held_out_features=[dict(expected=n,sample=s) for n,s in heldout],cloud=False,capture=False,original_files_modified=False,other_meeting_quality_verified=False)
        return archive,report
    finally:extractor.close()


def save_new(archive,path):
    path=Path(path)
    if path.exists() or path.is_symlink():raise ValueError('Existing voice archive must not be overwritten')
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    if path.parent.is_symlink():raise ValueError('Unsafe archive folder')
    data=json.dumps(archive,ensure_ascii=False,separators=(',',':')).encode()
    fd,temp=tempfile.mkstemp(prefix='.voices-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as file:file.write(data);file.flush();os.fsync(file.fileno())
        # Link provides exclusive create; concurrent enrollment cannot overwrite.
        os.link(temp,path);os.chmod(path,0o600)
    finally:os.unlink(temp)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--cache',type=Path,required=True);p.add_argument('--names',nargs='+',required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--report',type=Path,required=True);p.add_argument('--confirmed-local-use',action='store_true')
    a=p.parse_args();archive,report=build_archive(a.cache,a.names,Path(__file__).resolve().parents[1],confirmed=a.confirmed_local_use)
    save_new(archive,a.output);a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');os.chmod(a.report,0o600)
    print(json.dumps(dict(people=report['training_samples'],independent_checks=len(report['held_out']),accepted=sum(c['predicted'] is not None for c in report['held_out']),cloud=False,capture=False),ensure_ascii=False))
