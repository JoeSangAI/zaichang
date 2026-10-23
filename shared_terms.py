"""Read-only spelling guides from configured `## 转写词表` owners."""
from __future__ import annotations
import json, os, sys, time, unicodedata
from pathlib import Path
from runtime_config import connectors
sys.dont_write_bytecode = True
HEADING = '## 转写词表'
SEP, ITEM_SEP = '｜', '、'
MAX_ROWS = 400
SKIP_PARTS = {'_archive', 'node_modules', '.runtime', '.git', '__pycache__', '.venv', 'venv'}
_COMPILED = [0.0, None, None]

class TermTableError(ValueError):
    pass


class Row:
    def __init__(self, term: str, aliases: list[str] | None = None, misheard: list[str] | None = None):
        self.term, self.aliases, self.misheard = term, list(aliases or []), list(misheard or [])

    def words(self) -> list[str]:
        return [self.term, *self.aliases]

    def render(self) -> str:
        line = f"- {self.term}"
        if self.aliases or self.misheard:
            line += SEP + ITEM_SEP.join(self.aliases)
        if self.misheard:
            line += SEP + ITEM_SEP.join(self.misheard)
        return line

    def as_dict(self) -> dict:
        return {"term": self.term, "aliases": self.aliases, "misheard": self.misheard}


def valid_word(word: str) -> bool:
    if not isinstance(word, str) or not word or word != word.strip() or len(word) > 64:
        return False
    if any(c in word for c in (SEP, ITEM_SEP, "|", "\n", "[", "]", "`", "*")):
        return False
    if any(unicodedata.category(c).startswith("C") for c in word):
        return False
    return len(word) <= 20 if not word.isascii() else len(word.split()) <= 7


def _items(value: str) -> list[str]:
    return [item.strip() for item in value.split(ITEM_SEP) if item.strip()]


def _section_bounds(lines: list[str]) -> tuple[int, int] | None:
    starts = [i for i, line in enumerate(lines) if line.strip() == HEADING]
    if len(starts) > 1:
        raise TermTableError("duplicate_term_section")
    if not starts:
        return None
    end = next((i for i in range(starts[0] + 1, len(lines)) if lines[i].startswith("#") and not lines[i].startswith("###")), len(lines))
    return starts[0], end


def parse(text: str) -> list[Row]:
    """Rows in file order. Invalid rows raise so that a broken owner is visible."""
    lines = text.splitlines()
    bounds = _section_bounds(lines)
    if bounds is None:
        return []
    rows: list[Row] = []
    seen: dict[str, Row] = {}
    for number, line in enumerate(lines[bounds[0] + 1:bounds[1]], bounds[0] + 2):
        if not line.startswith("- "):
            continue
        parts = line[2:].split(SEP)
        if len(parts) > 3:
            raise TermTableError(f"row_shape:{number}")
        term = parts[0].strip()
        aliases = _items(parts[1]) if len(parts) > 1 else []
        misheard = _items(parts[2]) if len(parts) > 2 else []
        if not all(valid_word(w) for w in [term, *aliases, *misheard]):
            raise TermTableError(f"invalid_word:{number}")
        key = term.casefold()
        if key in seen:  # merge accidental duplicates instead of failing reads
            row = seen[key]
            row.aliases += [a for a in aliases if a not in row.aliases]
            row.misheard += [m for m in misheard if m not in row.misheard]
            continue
        row = Row(term, aliases, misheard)
        seen[key] = row
        rows.append(row)
    if len(rows) > MAX_ROWS:
        raise TermTableError("too_many_rows")
    return rows


def read_owner(path: Path) -> list[Row]:
    return parse(Path(path).read_text(encoding="utf-8"))


def _read(path, layer):
    try:
        if path.is_symlink() or path.stat().st_size > 1024 * 1024:
            raise ValueError('invalid_term_owner')
        rows = [dict(row.as_dict(), layer=layer, path=str(path)) for row in read_owner(path)]
        return dict(path=str(path), layer=layer, rows=rows, error=None)
    except (OSError, ValueError) as exc:
        return dict(path=str(path), layer=layer, rows=[], error=type(exc).__name__)


def compiled_owners(max_age=60.0):
    config = connectors()
    key = json.dumps(config, sort_keys=True)
    if len(_COMPILED) != 3 or _COMPILED[2] != key or _COMPILED[1] is None or time.monotonic() - _COMPILED[0] > max_age:
        paths = {}
        for field, layer in [('general_terms', 'general'), ('people_terms', 'people')]:
            if config.get(field): paths[Path(config[field])] = layer
        for root in config.get('project_roots', []):
            if Path(root).is_symlink(): continue
            for base, dirs, files in os.walk(root, followlinks=False):
                dirs[:] = sorted(d for d in dirs if d not in SKIP_PARTS and not d.startswith('.') and 'archive' not in d.casefold() and '归档' not in d and not (Path(base)/d).is_symlink())
                if len(Path(base).parts) - len(Path(root).parts) >= 5: dirs[:] = []
                if Path(base).name == '知识库' and (Path(base).parent/'实体与术语.md').is_file(): continue
                if '实体与术语.md' in files:
                    paths.setdefault(Path(base)/'实体与术语.md', 'project')
        _COMPILED[:] = [time.monotonic(), [_read(path, layer) for path, layer in paths.items()], key]
    return _COMPILED[1]

PROJECT_MIN_SCORE=3.0
TERM_LIMIT=300

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

def meeting_segments(cache_dir):
    """Latest finalized segments, respecting provider replay removals."""
    from audio_sources import transcript_tracks
    latest={}
    for track in transcript_tracks(Path(cache_dir)):
        path=Path(cache_dir)/f'{track}-transcript.jsonl'
        if path.is_symlink() or not path.is_file():continue
        for line in path.read_text(encoding='utf-8',errors='replace').splitlines():
            try:event=json.loads(line)
            except ValueError:continue
            if isinstance(event,dict) and event.get('type')=='asr_replay':
                for key in event.get('discard_segment_ids',[]):latest.pop((track,key),None)
            if isinstance(event,dict) and event.get('type')=='segment' and event.get('final') is True and isinstance(event.get('text'),str):
                latest[(track,event.get('segment_id'))]=event['text']
    return latest

def meeting_text(cache_dir,limit=400000):
    return ''.join(meeting_segments(cache_dir).values())[-limit:]

def meeting_title(cache_dir):
    path=Path(cache_dir)/'display-info.json'
    try:value=json.loads(path.read_text(encoding='utf-8')) if path.is_file() and not path.is_symlink() else {}
    except (OSError,ValueError):return ''
    title=value.get('title') if isinstance(value,dict) else None
    return title if isinstance(title,str) and len(title)<=240 else ''

def meeting_project(cache_dir):
    return detect_project(meeting_text(cache_dir),title=meeting_title(cache_dir))

def project_rows(project_dir=None):
    """Rows for one meeting in priority order: project, shared people, general."""
    owners = compiled_owners()
    chosen = [owner for owner in owners if owner['layer'] != 'project']
    if project_dir is not None:
        directory = Path(project_dir).resolve()
        candidates = [o for o in owners if o['layer'] == 'project' and directory.is_relative_to(Path(o['path']).parent.resolve())]
        if candidates:
            chosen.append(max(candidates, key=lambda o: len(Path(o['path']).parts)))
    order = {'project': 0, 'people': 1, 'general': 2}
    return sorted([row for owner in chosen for row in owner['rows']], key=lambda row: order[row['layer']])

def meeting_projects(cache_dir,text=None):
    """Detect from this meeting's text and title; no derived term snapshot."""
    return detect_projects(meeting_text(cache_dir) if text is None else text,title=meeting_title(cache_dir))

def cleanup_terms(project_dir=None,limit=TERM_LIMIT,*,project_dirs=None):
    """Structured spelling evidence; ambiguous mishearings are never replacements."""
    rows=[];seen={}
    for directory in project_dirs or [project_dir]:
        for row in project_rows(directory):
            row=dict(row,misheard=list(row['misheard']) if row['layer']=='project' and directory is not None else [])
            key=row['term'].casefold()
            if key not in seen:
                merged=dict(row,aliases=list(row['aliases']),misheard=list(row['misheard']))
                rows.append(merged);seen[key]=merged
            else:
                if row['layer']=='project' and directory is not None:seen[key]['layer']='project'
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

def term_guide(project_dir=None,limit=TERM_LIMIT,*,project_dirs=None):
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
