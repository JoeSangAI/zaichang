"""Read-only candidates from explicitly saved local transcription terms."""
from __future__ import annotations
import argparse, hashlib, importlib.util, json, re, signal, sys, unicodedata
from pathlib import Path
sys.dont_write_bytecode = True
TERM_TABLE = Path(__file__).resolve().parent/'term_table.py'
MAX_SELECTED = 300

def valid_term(word):
    if not isinstance(word,str) or word != word.strip() or not word or len(word)>128:
        return False
    if any(unicodedata.category(c).startswith('C') for c in word):return False
    return len(word)<=15 if not word.isascii() else len(word.split())<=7

def validate_vocabulary(value):
    if not isinstance(value,dict) or len(value)>MAX_SELECTED:raise ValueError('asr_terms_invalid')
    if any(not valid_term(k) or type(v) is not int or not 1<=v<=5 for k,v in value.items()):raise ValueError('asr_terms_invalid')
    if len(json.dumps(value,ensure_ascii=False).encode())>24576:raise ValueError('asr_terms_too_large')
    return dict(sorted(value.items()))

def request_vocabulary(request):
    value=request.get('asr_vocabulary')
    if value is None:return {}
    if request.get('asr_terms_confirmed') is not True:raise ValueError('asr_terms_not_confirmed')
    return validate_vocabulary(value)

_TABLES={};_COMPILED=[0.0,None]

def term_table(module_path=TERM_TABLE):
    if module_path not in _TABLES:
        spec=importlib.util.spec_from_file_location('_zaichang_term_table',module_path)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);_TABLES[module_path]=module
    return _TABLES[module_path]

def compiled_owners(max_age=60.0):
    """All owners, re-walked at most once a minute so learned words appear quickly."""
    import time
    if _COMPILED[1] is None or time.monotonic()-_COMPILED[0]>max_age:
        _COMPILED[:]=[time.monotonic(),term_table().compile_all()]
    return _COMPILED[1]

def candidates(module_path=TERM_TABLE):
    table=term_table(module_path)
    owners=table.compile_all()
    if len(owners)>512:raise ValueError('term_source_limit')
    collected={};source_hashes={}
    for owner in owners:
        path=Path(owner['path'])
        if owner['error']:raise ValueError('term_table_invalid')
        label={'general':'通用','people':'人物'}.get(owner['layer']) or path.parent.name
        source_hashes[label]=hashlib.sha256(path.read_bytes()).hexdigest()
        for row in owner['rows']:
            for word in [row['term'],*row['aliases']]:
                if valid_term(word):collected.setdefault(word,set()).add(label)
    if len(collected)>2048:raise ValueError('term_candidate_limit')
    rows=[dict(word=word,sources=sorted(labels)[:8]) for word,labels in sorted(collected.items(),key=lambda pair:pair[0].casefold())]
    digest=hashlib.sha256(json.dumps(source_hashes,sort_keys=True).encode()).hexdigest()
    return dict(schema=1,status='ok',requires_selection=True,source_digest=digest,source_count=len(source_hashes),candidates=rows)

PROJECT_MIN_SCORE=3.0
VOCABULARY_LIMIT=300

def _searchable(word):
    # Short Latin acronyms (AE, GE, TA) and single characters match too much ordinary speech.
    return len(word)>=3 if word.isascii() else len(word)>=2

def project_scores(text,owners=None):
    """Deterministic, local: which project's own words occur in this transcript text."""
    owners=owners if owners is not None else compiled_owners()
    projects=[o for o in owners if o['layer']=='project' and not o['error'] and o['rows']]
    spread={}
    for owner in projects:
        for word in {w.casefold() for r in owner['rows'] for w in [r['term'],*r['aliases'],*r['misheard']] if _searchable(w)}:
            spread[word]=spread.get(word,0)+1
    folded=text.casefold();scores=[]
    for owner in projects:
        words={w.casefold() for r in owner['rows'] for w in [r['term'],*r['aliases'],*r['misheard']] if _searchable(w)}
        score=sum(min(folded.count(w),5)/spread[w] for w in words if w in folded)
        if score>0:scores.append((round(score,2),owner['path']))
    return sorted(scores,reverse=True)

def detect_project(text,owners=None,title=''):
    """The owning project directory when one project clearly dominates; otherwise None.
    The meeting title counts three times: it is a summary of the whole meeting."""
    scores=project_scores(text+('\n'+title)*3 if title else text,owners)
    if not scores or scores[0][0]<PROJECT_MIN_SCORE:return None
    if len(scores)>1 and scores[0][0]<2*scores[1][0]:return None
    return Path(scores[0][1]).parent

def detect_projects(text,owners=None,title=''):
    """All above-threshold projects for cleanup; ownership detection stays singular."""
    scores=project_scores(text+('\n'+title)*3 if title else text,owners)
    return [Path(path).parent for score,path in scores if score>=PROJECT_MIN_SCORE]

def meeting_text(cache_dir,limit=400000):
    """Final segment text already on disk for this meeting; nothing is sent anywhere."""
    from audio_sources import transcript_tracks
    latest={}
    for track in transcript_tracks(Path(cache_dir)):
        path=Path(cache_dir)/f'{track}-transcript.jsonl'
        if path.is_symlink() or not path.is_file():continue
        for line in path.read_text(encoding='utf-8',errors='replace').splitlines():
            try:event=json.loads(line)
            except ValueError:continue
            if isinstance(event,dict) and event.get('type')=='segment' and isinstance(event.get('text'),str):
                latest[(track,event.get('segment_id'))]=event['text']
    return ''.join(latest.values())[-limit:]

def meeting_title(cache_dir):
    path=Path(cache_dir)/'display-info.json'
    try:value=json.loads(path.read_text(encoding='utf-8')) if path.is_file() and not path.is_symlink() else {}
    except (OSError,ValueError):return ''
    title=value.get('title') if isinstance(value,dict) else None
    return title if isinstance(title,str) and len(title)<=240 else ''

def meeting_project(cache_dir):
    return detect_project(meeting_text(cache_dir),title=meeting_title(cache_dir))

def merged_vocabulary(manual,project_dir=None,saved=None):
    """Explicit picks first (they keep their weight), then the standing automatic words for this
    meeting, then words saved by an earlier part of the same meeting."""
    words=dict(manual or {})
    for source in (auto_vocabulary(project_dir),saved or {}):
        for word,weight in source.items():
            if len(words)>=VOCABULARY_LIMIT:break
            words.setdefault(word,weight)
    return validate_vocabulary(words)

def project_rows(project_dir=None):
    """Rows for one meeting in priority order: project, shared people, general."""
    rows=term_table().for_project(project_dir)
    order={'project':0,'people':1,'general':2}
    return sorted(rows,key=lambda row:order[row['layer']])

def auto_vocabulary(project_dir=None,limit=VOCABULARY_LIMIT):
    """Use only accepted spellings and spoken aliases; known errors are never submitted as hotwords."""
    weight={'project':4,'people':3,'general':2};words={}
    for row in project_rows(project_dir):
        for word in [row['term'],*row['aliases']]:
            if valid_term(word) and word not in words and len(words)<limit:words[word]=weight[row['layer']]
    return validate_vocabulary(words)

def cleanup_terms(project_dir=None,limit=VOCABULARY_LIMIT,*,project_dirs=None):
    """Structured spelling evidence; ambiguous mishearings are never replacements."""
    rows=[];seen={}
    for directory in project_dirs or [project_dir]:
        for row in project_rows(directory):
            key=row['term'].casefold()
            if key not in seen:
                merged=dict(row,aliases=list(row['aliases']),misheard=list(row['misheard']))
                rows.append(merged);seen[key]=merged
            else:
                for field in ('aliases','misheard'):
                    seen[key][field]=list(dict.fromkeys([*seen[key][field],*row[field]]))
    rows.sort(key=lambda row:{'project':0,'people':1,'general':2}[row['layer']])
    targets={};known={}
    for row in rows:
        for word in [row['term'],*row['aliases']]:
            known.setdefault(word.casefold(),set()).add(row['term'].casefold())
        for word in row['misheard']:
            targets.setdefault(word.casefold(),set()).add(row['term'].casefold())
    conflicts={word for word,values in targets.items()
               if len(values|known.get(word,set()))>1}
    result=[]
    for row in rows[:limit]:
        value=dict(row)
        value['misheard']=[word for word in row['misheard'] if word.casefold() not in conflicts]
        result.append(value)
    return result, sorted(conflicts)

def term_guide(project_dir=None,limit=VOCABULARY_LIMIT,*,project_dirs=None):
    """Prompt lines for the pause cleanup: standard spelling, aliases and known misrecognitions."""
    rows,conflicts=cleanup_terms(project_dir,limit,project_dirs=project_dirs)
    lines=[]
    for row in rows:
        line=row['term']
        if row['aliases']:line+='（也称'+'、'.join(row['aliases'])+'）'
        safe=row['misheard']
        if safe:line+='；常被误识为'+'、'.join(safe)
        lines.append(line[:300])
    for word in sorted(conflicts):
        lines.append('待核：'+word+' 存在词表冲突，保留原写法，不自动纠正。')
    return lines

def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    def timeout(*_):raise TimeoutError('term_source_timeout')
    signal.signal(signal.SIGALRM,timeout);signal.setitimer(signal.ITIMER_REAL,2.5)
    try:
        value=candidates();raw=json.dumps(value,ensure_ascii=False)
        if len(raw.encode())>256*1024:raise ValueError('term_output_limit')
        print(raw);return 0
    except Exception:
        print(json.dumps(dict(schema=1,status='unavailable',requires_selection=True,candidates=[])));return 1
    finally:signal.setitimer(signal.ITIMER_REAL,0)
if __name__=='__main__':raise SystemExit(main())
