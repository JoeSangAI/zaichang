"""Meeting-scoped, offline speaker reconciliation over preserved PCM.

A confirmed roster constrains candidates, not confidence. Original text, PCM and
human corrections are never rewritten. The app reads a reversible, hash-bound
annotation sidecar. No cross-meeting enrollment, capture, credentials or network.
"""
from pathlib import Path
import argparse
import collections
import ctypes as C
import hashlib
import json
import math
import os
import time

MODEL_SHA = 'f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def latest_events(directory):
    latest = {}
    discarded = set()
    hashes = {}
    for path in sorted(Path(directory).glob('*-transcript.jsonl')):
        hashes[path.name] = sha(path)
        for line in path.read_text().splitlines():
            e = json.loads(line)
            if e.get('type') == 'asr_replay':
                discarded.update(e.get('discard_segment_ids', []))
            elif e.get('type') == 'segment':
                old = latest.get(e['segment_id'])
                if old is None or e.get('revision', 0) > old.get('revision', 0):
                    latest[e['segment_id']] = e
    return sorted((e for i, e in latest.items() if i not in discarded), key=lambda e: (e['start'], e['segment_id'])), hashes


def select_prediction(predictions, duration, *, known=False):
    # Padded context is allowed only with direct agreement or an isolated short
    # span; a strong conflicting direct voice blocks its neighbor's identity.
    direct = predictions[0] if predictions else None
    eligible = [p for p in predictions if p and p['score'] >= (.64 if known else .55)
                and p['margin'] >= (.20 if known else .15)]
    if not eligible or len({p['winner'] for p in eligible}) != 1:
        return None
    best = max(eligible, key=lambda p: p['score'])
    if direct and direct['score'] >= .45 and direct['margin'] >= .10 and direct['winner'] != best['winner']:
        return None
    if known and duration < .25:
        return None  # Never replace an existing named-slot short word by its neighbor.
    return best


class LocalExtractor:
    def __init__(self, root):
        import numpy as np
        self.np = np
        model = root / 'native/local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx'
        if sha(model) != MODEL_SHA:
            raise ValueError('Unexpected local embedding model')
        self.lib = C.CDLL(str(root / 'native/local-embedding-install/runtime/lib/libsherpa-onnx-c-api.dylib'))
        class Config(C.Structure):
            _fields_ = [('model', C.c_char_p), ('num_threads', C.c_int32), ('debug', C.c_int32), ('provider', C.c_char_p)]
        def fn(name, args, result=None):
            f = getattr(self.lib, 'SherpaOnnx' + name); f.argtypes = args; f.restype = result
            return f
        ptr, fp = C.c_void_p, C.POINTER(C.c_float)
        version = fn('GetVersionStr', [], C.c_char_p)()
        if version not in [b'1.13.8', b'v1.13.8']:
            raise ValueError('Unexpected embedding runtime')
        config = Config(str(model).encode(), 1, 0, b'cpu')
        self.extractor = fn('CreateSpeakerEmbeddingExtractor', [C.POINTER(Config)], ptr)(C.byref(config))
        if not self.extractor or fn('SpeakerEmbeddingExtractorDim', [ptr], C.c_int32)(self.extractor) != 192:
            raise ValueError('Embedding extractor unavailable')
        self.stream = fn('SpeakerEmbeddingExtractorCreateStream', [ptr], ptr)
        self.wave = fn('OnlineStreamAcceptWaveform', [ptr, C.c_int32, fp, C.c_int32])
        self.finish = fn('OnlineStreamInputFinished', [ptr])
        self.ready = fn('SpeakerEmbeddingExtractorIsReady', [ptr, ptr], C.c_int32)
        self.compute = fn('SpeakerEmbeddingExtractorComputeEmbedding', [ptr, ptr], fp)
        self.destroy_stream = fn('DestroyOnlineStream', [ptr])
        self.destroy_vector = fn('SpeakerEmbeddingExtractorDestroyEmbedding', [fp])
        self.destroy_extractor = fn('DestroySpeakerEmbeddingExtractor', [ptr])

    def extract(self, pcm):
        np = self.np
        values = np.asarray(pcm, dtype='float32') / 32768
        if len(values) < 4000 or len(values) > 64000 or not np.isfinite(values).all():
            return None
        if np.sqrt(np.mean(values * values)) < .001 or np.mean(abs(values) >= .98) > .01:
            return None
        stream = self.stream(self.extractor)
        try:
            self.wave(stream, 16000, values.ctypes.data_as(C.POINTER(C.c_float)), len(values))
            self.finish(stream)
            if not self.ready(self.extractor, stream): return None
            vector = self.compute(self.extractor, stream)
            if not vector: return None
            try: out = np.ctypeslib.as_array(vector, shape=(192,)).copy()
            finally: self.destroy_vector(vector)
            norm = np.linalg.norm(out)
            return out / norm if np.isfinite(out).all() and norm > 1e-12 else None
        finally:
            self.destroy_stream(stream)

    def close(self):
        if self.extractor:
            self.destroy_extractor(self.extractor); self.extractor = None


def key_token(key):
    return '\x1f'.join(key[k] for k in ['session', 'source', 'epoch', 'identity'])


def reconcile(directory, roster_names, root):
    import numpy as np
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir(): raise ValueError('Unsafe cache directory')
    metadata = json.loads((directory / 'meeting.json').read_text())
    names = json.loads((directory / 'session-names.json').read_text())
    session = metadata['session']
    if names['session'] != session or len(set(roster_names)) != len(roster_names): raise ValueError('Invalid roster')
    roster = []
    for name in roster_names:
        matches = [r for r in names['speakers'] if r['name'] == name]
        if len(matches) != 1: raise ValueError('Roster must resolve unambiguously to named voices')
        roster.append(matches[0])
    events, hashes = latest_events(directory)
    units = []
    for e in events:
        if not e.get('final') or not e.get('end_time_known'): continue
        raw = e.get('speaker_runs') or [e]
        if ''.join(r['text'] for r in raw) != e['text']: raise ValueError('Invalid original runs')
        units.extend({'parent': e, 'run': r.copy()} for r in raw)
    manifests = {}; audio = {}; origins = {}
    for track in sorted({e['source_id'] for e in events}):
        manifest_path = directory / (track + '-manifest.json')
        m = json.loads(manifest_path.read_text())
        if not m.get('ended') or m.get('error'): raise ValueError('Only stopped, complete recordings can be reconciled')
        if m['track'] != track or m['written_bytes'] > 512 * 1024 * 1024: raise ValueError('Invalid PCM manifest')
        chunks = []
        for c in m['chunks']:
            path = directory / f'{track}-{c["index"]:06}.pcm'
            if path.is_symlink(): raise ValueError('Unsafe PCM path')
            chunks.append(path.read_bytes())
        data = b''.join(chunks)
        if len(data) != m['written_bytes']: raise ValueError('Incomplete preserved PCM')
        audio[track] = np.frombuffer(data, dtype='<i2'); origins[track] = m['origin_uptime']
        manifests[manifest_path.name] = sha(manifest_path)
    absolute_origin = metadata.get('capture_origin_uptime', min(origins.values()))
    offsets = {t: o - absolute_origin for t, o in origins.items()}
    extractor = LocalExtractor(root)
    def snippet(source, lo, hi):
        if not (math.isfinite(lo) and math.isfinite(hi)) or hi <= lo: return None
        offset = offsets[source]
        return extractor.extract(audio[source][max(0, round((lo-offset)*16000)):max(0, round((hi-offset)*16000))])
    def original_key(e, r):
        s = r['speaker']
        if s.get('basis') != 'anonymous_cluster': return None
        return dict(session=session, source=e['source_id'], epoch=e['epoch'], identity='slot:' + str(s['cluster_id']))
    tokens = [key_token(p['key']) for p in roster]
    anchors = []
    try:
        for person, token in zip(roster, tokens):
            good = [u for u in units if (k := original_key(u['parent'], u['run'])) and key_token(k) == token
                    and u['run']['end'] - u['run']['start'] >= 3 and not u['parent'].get('quality_flags')]
            if len(good) < 4: raise ValueError('Insufficient stable named voice examples')
            selected = good[::max(1, len(good)//12)][:12]
            for u in selected:
                r = u['run']; lo = r['start']+.15; hi = min(r['end']-.15, lo+3.5)
                v = snippet(u['parent']['source_id'], lo, hi)
                if v is not None: anchors.append((token, r['start'], v))
            if sum(a[0] == token for a in anchors) < 4: raise ValueError('Insufficient audible named voice examples')
        vectors = np.array([a[2] for a in anchors]); anchor_tokens = np.array([a[0] for a in anchors]); anchor_times = np.array([a[1] for a in anchors])
        # Require independent examples of each named voice to match one another.
        calibration = []
        for index, (token, start, vector) in enumerate(anchors):
            scores = vectors @ vector
            ranking = sorted(((t, float(max(scores[(anchor_tokens==t) & (np.arange(len(anchors))!=index)]))) for t in tokens), key=lambda x:x[1], reverse=True)
            if ranking[0][0] != token or ranking[0][1] < .48 or ranking[0][1]-ranking[1][1] < .12:
                raise ValueError('Named voice examples are not sufficiently distinct')
            calibration.append(dict(token=token, score=ranking[0][1], margin=ranking[0][1]-ranking[1][1]))
        protected_parents = {a['id'] for a in names['assignments'] if ':word:' not in a['id'] and ':turn:' not in a['id']}
        protected_anchors = names.get('runAnchors', [])
        by_parent = collections.defaultdict(list); decisions = []; counts = collections.Counter()
        for index, u in enumerate(units):
            e, r = u['parent'], u['run']; key = original_key(e,r); token = key_token(key) if key else None
            known = token in tokens
            protected = e['segment_id'] in protected_parents or any(a['parent']==e['segment_id'] and a['start']<r['end'] and a['end']>r['start'] for a in protected_anchors)
            duration = r['end']-r['start']; predictions = []
            if not protected and not e.get('quality_flags'):
                windows = [(r['start'], min(r['end'], r['start']+4))]
                if duration < 2:
                    center=(r['start']+r['end'])/2; windows.append((max(0,center-1.1),center+1.1))
                elif duration>4: windows.append((max(r['start'],r['end']-4),r['end']))
                for lo,hi in windows:
                    v=snippet(e['source_id'],lo,hi)
                    if v is None: predictions.append(None); continue
                    scores=vectors@v
                    ranking=sorted(((t,float(max(scores[(anchor_tokens==t)&(abs(anchor_times-r['start'])>1)]))) for t in tokens),key=lambda x:x[1],reverse=True)
                    predictions.append(dict(winner=ranking[0][0],score=ranking[0][1],margin=ranking[0][1]-ranking[1][1],window=[lo,hi]))
            winner=select_prediction(predictions,duration,known=known)
            # A padded short window must not absorb a nearby known different voice.
            if winner and duration<2 and winner['window'] != [r['start'],min(r['end'],r['start']+4)]:
                left,right=winner['window']
                conflicting=any(v['parent']['source_id']==e['source_id'] and v['run']['start']<right and v['run']['end']>left
                                and v is not u and (k:=original_key(v['parent'],v['run'])) and key_token(k) in tokens and key_token(k)!=winner['winner']
                                for v in units)
                if conflicting: winner=None
            result=r.copy(); method='preserved'
            if not protected and winner and winner['winner'] != token:
                target=roster[tokens.index(winner['winner'])]['key']
                result['speaker']={'basis':'meeting_reconciliation','identity_key':target,'source_id':e['source_id'],'epoch':e['epoch']}
                method='acoustic_match';counts['reassigned' if known else 'resolved']+=1
            elif not protected and key is not None and not known:
                result['speaker']={'basis':'unknown','reason':'unconfirmed_model_slot','source_id':e['source_id'],'epoch':e['epoch']}
                method='unstable_extra_slot';counts['unstable_extra_slots']+=1
            elif not known: counts['unresolved']+=1
            by_parent[e['segment_id']].append(result)
            decisions.append(dict(parent=e['segment_id'],start=r['start'],end=r['end'],method=method,predictions=predictions))
            if (index+1)%200==0: print(json.dumps({'processed':index+1,'expected':len(units)}),flush=True)
        records=[]
        for e in events:
            runs=by_parent.get(e['segment_id'])
            if not runs: continue
            if all(r['speaker']==old['speaker'] for r,old in zip(runs,e.get('speaker_runs') or [e])): continue
            speakers=[r['speaker'] for r in runs]
            if all(s==speakers[0] for s in speakers): speaker=speakers[0]
            else: speaker={'basis':'multiple','reason':'speaker_change'}
            records.append(dict(segment_id=e['segment_id'],revision=e.get('revision',0),text_sha256=hashlib.sha256(e['text'].encode()).hexdigest(),start=e['start'],end=e['end'],speaker=speaker,speaker_runs=[{k:r[k] for k in ['start','end','text','speaker']} for r in runs]))
        return dict(schema=1,cache_id=directory.name,session=session,roster=[p['key'] for p in roster],source_sha256=hashes,manifest_sha256=manifests,model_sha256=MODEL_SHA,records=records,summary=dict(counts),provenance={'roster_confirmed_by_user':True,'original_names_sha256':sha(directory/'session-names.json'),'anchors':len(anchors),'calibration':calibration,'decisions':decisions,'no_text_identity_inference':True,'cloud':False,'capture':False})
    finally: extractor.close()


def apply_plan(directory, plan, output):
    directory=Path(directory); output=Path(output)
    if plan['cache_id']!=directory.name or json.loads((directory/'meeting.json').read_text())['session']!=plan['session']: raise ValueError('Wrong meeting')
    for name,expected in {**plan['source_sha256'],**plan['manifest_sha256'],'session-names.json':plan['provenance']['original_names_sha256']}.items():
        if Path(name).name!=name or sha(directory/name)!=expected: raise ValueError('Source changed; regenerate plan')
    target=directory/'speaker-reconciliation.json'
    if target.exists(): raise ValueError('Reconciliation already exists; preserve/review it before replacement')
    data=json.dumps(plan,ensure_ascii=False,separators=(',',':')).encode()
    if len(data)>2*1024*1024: raise ValueError('Sidecar too large')
    temporary=directory/'.speaker-reconciliation.pending'
    with temporary.open('xb') as file:
        os.chmod(temporary,0o600);file.write(data);file.flush();os.fsync(file.fileno())
    temporary.replace(target)
    print(json.dumps({'applied':True,'cache_id':directory.name,'original_transcripts_unchanged':True,'sidecar':str(target)}))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache',type=Path,required=True)
    parser.add_argument('--roster',nargs='+',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args();started=time.monotonic()
    plan=reconcile(args.cache,args.roster,Path(__file__).resolve().parents[1])
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(plan,ensure_ascii=False,indent=2)+'\n');os.chmod(args.output,0o600)
    print(json.dumps({'expected_records':len(plan['records']),'summary':plan['summary'],'seconds':round(time.monotonic()-started,2)},ensure_ascii=False))
    if args.apply: apply_plan(args.cache,plan,args.output)
