#!/usr/bin/env python3
"""Replay into a fresh isolated Assistant store; real inference is opt-in (omit --offline)."""
from __future__ import annotations
from bisect import bisect_right
from datetime import datetime
from zoneinfo import ZoneInfo
import argparse
import ast
import asyncio
import copy
import json
import math
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from assistant_runtime import AssistantRuntime, AssistantStore, OVERVIEW_SCHEMA, EMPTY_OVERVIEW, _compact
from codex_runtime import CodexRuntime
from meeting_context import _safe_turn


def ui_sources():
    """Parse, never execute the official build/launch-lock entry point."""
    names = []
    for node in ast.walk(ast.parse((ROOT / "scripts/build_offline.py").read_text())):
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "ui" for t in node.targets):
            names = ast.literal_eval(node.value)
        elif isinstance(node, ast.AugAssign) and isinstance(node.target, ast.Name) and node.target.id == "ui":
            names += ast.literal_eval(node.value)
    return [next(p for p in (ROOT/"native"/(name+".swift"), ROOT/"native/checks"/(name+".swift")) if p.is_file()) for name in names]


def native_projection(cache: Path, out: Path) -> dict:
    build = out / "projection-helper"
    build.mkdir(parents=True, exist_ok=True)
    sources = ui_sources()
    original = ROOT / "native/MeetingAssistantUI.swift"
    copy = build / original.name
    # Only replace the executable entry point in the isolated copy.
    copy.write_text(original.read_text().replace("@main struct UIEntry", "struct UIEntry"))
    sources[sources.index(original)] = copy
    binary = build / "ReplayMeetingProjection"
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target", "arm64-apple-macosx15.0",
               "-module-cache-path", str(build/"module-cache"), *map(str,sources), str(ROOT/"scripts/replay_meeting_projection.swift"), "-o", str(binary)]
    with (build/"compile.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([str(binary), str(cache)], text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def projected_context(cache_id: str, out: Path, *, database: Path | None = None, cache_root: Path | None = None) -> dict:
    # Exact cache identity, one SQLite read snapshot, no writer nor service startup.
    if not cache_id or Path(cache_id).name != cache_id or cache_id in (".", ".."):
        raise ValueError("invalid_cache_id")
    base = Path.home()/"Library/Application Support/MeetingAssistant"
    database = database or base/"AgentContext/context.sqlite"
    cache = (cache_root or base/"SessionCache")/cache_id
    context = None
    try:
        if database.is_file():
            with sqlite3.connect(database.resolve().as_uri()+"?mode=ro", uri=True) as db:
                db.row_factory = sqlite3.Row
                db.execute("PRAGMA query_only=ON"); db.execute("BEGIN")
                for meeting in db.execute("SELECT session,metadata FROM meetings"):
                    meta = json.loads(meeting["metadata"])
                    if meta.get("cache_id") != cache_id:
                        continue
                    segments = []
                    for record in db.execute("SELECT revision,start,end,payload FROM segments WHERE session=? AND deleted=0 ORDER BY start,parent", (meeting["session"],)):
                        for raw in json.loads(record["payload"]):
                            turn = _safe_turn(raw)
                            if turn["final"] is not True:
                                continue
                            segments.append({"id": turn["id"], "revision": record["revision"], "text": turn["text"],
                                "speaker": turn.get("speaker") or "", "speaker_uncertain": turn.get("uncertain", False),
                                "quality_flags": turn.get("quality_flags", []), "text_quality": turn.get("text_quality"), "final": True,
                                "start": turn.get("start") or record["start"], "end": turn.get("end") or record["end"] or record["start"]})
                    context = {"title": meta.get("title", ""), "cache_id": cache_id, "session_id": meeting["session"],
                               "context_database": str(database), "segments": segments, "source": "AgentContext/context.sqlite"}
                    # Stale/incomplete projections must use the same native cache rules.
                    newest = max((s["end"] for s in segments), default=0)
                    projection_mtime = max(p.stat().st_mtime for p in (database, Path(str(database)+"-wal")) if p.exists())
                    too_old = any(p.stat().st_mtime > projection_mtime for p in cache.glob("*-transcript.jsonl"))
                    if not segments or meta.get("projection_updating") or too_old or newest + 180 < meta.get("recording_elapsed_seconds", 0):
                        context = None
                    break
    except (sqlite3.Error, ValueError, KeyError, TypeError):
        context = None
    if context is None:
        context = native_projection(cache, out)
    context["segments"].sort(key=lambda s: (float(s.get("start") or 0), str(s["id"])))
    if not context["segments"]:
        raise ValueError("no_final_segments")
    return context


DATA_ROOT = Path.home() / "Library/Application Support/MeetingAssistant"


def load_context(cache_id: str, out: Path, *, database=None, cache_root=None) -> dict:
    # Lazy import: share the existing native fallback without coupling the runner
    # to AssistantRuntime, its store, its prompts or its scheduling policies.

    database = database or DATA_ROOT / "AgentContext/context.sqlite"
    cache_root = cache_root or DATA_ROOT / "SessionCache"
    context = projected_context(cache_id, out, database=database, cache_root=cache_root)
    metadata = {}
    try:
        if database.is_file():
            with sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True) as db:
                db.execute("PRAGMA query_only=ON")
                row = db.execute("SELECT metadata FROM meetings WHERE session=?",
                                 (context["session_id"],)).fetchone()
                if row:
                    candidate = json.loads(row[0])
                    if candidate.get("cache_id") == cache_id:
                        metadata = candidate
    except (sqlite3.Error, ValueError, TypeError):
        # projected_context may have succeeded through its native fallback.
        metadata = {}
    anchors = (metadata.get("absolute_clock") or {}).get("anchors") or []
    timestamp = min((a["unix_time"] for a in anchors), default=None)
    if timestamp is None:
        # Only metadata; never read audio or reimplement transcript interpretation.
        metadata = json.loads((cache_root / cache_id / "meeting.json").read_text())
        timestamp = metadata.get("created_at")
    if timestamp is None:
        raise ValueError("meeting_date_unavailable")
    context["meeting_date"] = datetime.fromtimestamp(float(timestamp), ZoneInfo("Asia/Shanghai")).date().isoformat()
    context["duration_seconds"] = max(
        float(metadata.get("recording_elapsed_seconds") or 0),
        max(float(s.get("end", s.get("start", 0))) for s in context["segments"]))
    return context


def number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(f"{name} must be a finite nonnegative number")
    return value


def integer(value, name):
    number(value, name)
    if not isinstance(value, int):
        raise ValueError(f"{name} must be an integer")
    return value


class MeetingClock:
    def __init__(self, context, *, speed=1.0, offline=False, sleep=asyncio.sleep):
        if number(speed, "speed") == 0:
            raise ValueError("speed must be positive")
        self.speed, self.offline, self.sleep = speed, offline, sleep
        self.now = 0.0
        self.rows = []
        for raw in context["segments"]:
            if raw.get("final") is not True:
                continue
            start = float(raw.get("start") or 0)
            end = float(raw["end"] if raw.get("end") is not None else start)
            number(start, "segment.start")
            number(end, "segment.end")
            if end < start:
                raise ValueError("segment.end before segment.start")
            self.rows.append({"id": raw["id"], "speaker": raw.get("speaker") or "",
                              "start": start, "end": end, "text": raw["text"]})
        if not self.rows:
            raise ValueError("no_final_segments")
        # Completed sentences are released at END, not START. Overlapping speech
        # therefore sorts by availability, with deterministic ties.
        self.rows.sort(key=lambda s: (s["end"], s["start"], str(s["id"])))
        self.ends = [s["end"] for s in self.rows]
        self.duration = max(self.ends[-1], number(context.get("duration_seconds", 0), "duration"))

    @property
    def revision(self):
        return bisect_right(self.ends, self.now)

    @property
    def ended(self):
        return self.now >= self.duration

    def visible(self):
        return self.rows[:self.revision]

    def response(self, rows):
        return {"at_seconds": self.now, "revision": self.revision,
                "ended": self.ended, "segments": rows}

    async def wait(self, after_revision, max_wait_seconds):
        integer(after_revision, "after_revision")
        number(max_wait_seconds, "max_wait_seconds")
        if after_revision > self.revision:
            raise ValueError("after_revision is ahead of the visible revision")
        if after_revision == self.revision and not self.ended:
            next_end = self.ends[self.revision] if self.revision < len(self.rows) else self.duration
            target = min(next_end, self.now + max_wait_seconds, self.duration)
            if not self.offline and target > self.now:
                await self.sleep((target - self.now) / self.speed)
            self.now = target
        return self.response(self.visible()[after_revision:])

    def read(self, offset, limit):
        integer(offset, "offset")
        integer(limit, "limit")
        return self.response(self.visible()[offset:offset + limit])

    def search(self, query):
        if not isinstance(query, str):
            raise ValueError("query must be a string")
        return self.response([s for s in self.visible() if query.casefold() in s["text"].casefold()])


class OfflineRuntime:
    """Fake agent, real driver/callbacks/clock. No subprocess, model, curl or network."""
    def __init__(self, *, on_request):
        self.on_request = on_request
        self.queue = asyncio.Queue()
        self.revision = self.waits = self.turns = self.calls = 0
        self.worker = None
        self.closed = False

    async def start(self):
        pass

    async def start_thread(self, cwd, **kwargs):
        self.thread_options = kwargs
        return {"thread": {"id": "offline-listener"}}

    async def start_turn(self, thread_id, text, *, output_schema=None):
        self.turns += 1
        turn_id = f"offline-turn-{self.turns}"
        self.worker = asyncio.create_task(self._listen(thread_id, turn_id))
        return {"turn": {"id": turn_id}}

    async def _listen(self, thread, turn):
        async def call(name, args):
            self.calls += 1
            result = await self.on_request("item/tool/call", {
                "threadId": thread, "turnId": turn, "callId": f"offline-call-{self.calls}",
                "tool": name, "arguments": args})
            if not result["success"]:
                raise RuntimeError(result["contentItems"][0]["text"])
            return json.loads(result["contentItems"][0]["text"])

        status, error = "completed", None
        try:
            await call("meeting_read", {"offset": max(0, self.revision - 3), "limit": 3})
            await call("meeting_search", {"query": "合作"})
            # A finite fake turn exercises continuation on the SAME thread.
            for _ in range(4):
                data = await call("meeting_wait", {"after_revision": self.revision, "max_wait_seconds": 60})
                self.revision = data["revision"]
                self.waits += 1
                if self.waits % 3 == 0 or data["ended"]:
                    await call("say", {"text": f"[离线假 agent] 已听到 {self.revision} 个定稿片段。"})
                if data["ended"]:
                    break
        except Exception as exc:
            status, error = "failed", {"message": str(exc)}
        await self.queue.put({"method": "turn/completed", "params": {
            "threadId": thread, "turn": {"id": turn, "status": status, "error": error}}})

    async def event(self, thread, *, timeout=120):
        return await asyncio.wait_for(self.queue.get(), timeout)

    async def interrupt(self, thread, turn):
        if self.worker: self.worker.cancel()
        await self.queue.put({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": turn, "status": "interrupted"}}})

    async def close(self):
        if self.worker:
            self.worker.cancel()
            await asyncio.gather(self.worker, return_exceptions=True)
        self.closed = True


class ReplayService(AssistantRuntime):
    """Production conversation/tool routes; only meeting arrival time is simulated."""
    def __init__(self, *args, context, timeline, speed=1, fake=False, **kwargs):
        super().__init__(*args, **kwargs)
        self.meeting_clock = MeetingClock(context, speed=speed, offline=fake)
        self.replay_context = context
        self.timeline = timeline
        self.token_total = {}
        self.current_turn = None
        self.work_started = {}

    def _schedule_overview(self, *args, **kwargs):
        # This entry point validates the assistant; P2's independent tests cover overview.
        pass

    async def _meeting_wait(self, workspace_id, args, task_id):
        after = args['after_revision']; maximum = args['max_wait_seconds']
        integer(after, 'after_revision'); number(maximum, 'max_wait_seconds')
        if after > self.revisions.get(workspace_id, 0): raise ValueError('invalid_revision')
        clock = self.meeting_clock
        # An unread production revision can be consumed without advancing the replay.
        if after == self.revisions.get(workspace_id, 0):
            start = clock.now
            await clock.wait(clock.revision, maximum)
            first_new = clock.now
            # Same batching policy as production, on the simulated meeting clock.
            while True:
                target = min(clock.now + self.wait_batch_seconds, start + maximum, clock.duration)
                if target > clock.now:
                    if not clock.offline: await asyncio.sleep((target-clock.now)/clock.speed)
                    clock.now = target
                await self.cmd_context(workspace_id, {**self.replay_context,
                    'segments': [{**s, 'final': True} for s in clock.visible()],
                    'meeting_state': 'ended' if clock.ended else 'recording'})
                if (clock.ended or clock.now >= start + maximum
                        or not self._batch_too_small(workspace_id, after, first_new, clock.now)):
                    break
        return self._meeting_delta(workspace_id, after)

    async def _dynamic_tool(self, row, params):
        result = await super()._dynamic_tool(row, params)
        clock = self.meeting_clock
        self.timeline['tools'].append({'at_seconds': clock.now, 'name': params.get('tool'), 'success': result['success']})
        if params.get('tool') == 'start_task' and result['success']:
            self.work_started[json.loads(result['contentItems'][0]['text'])['task_id']] = clock.now
        if params.get('tool') == 'say' and result['success']:
            args = params['arguments']; args = json.loads(args) if isinstance(args, str) else args
            self.timeline['says'].append({'at_seconds': clock.now, 'text': args['text'], 'context': clock.visible()[-3:]})
        return result

    async def _request_user(self, method, params):
        # Nobody is present to approve during a replay; decline and keep the record.
        self.timeline.setdefault('declined_requests', []).append({'at_seconds': self.meeting_clock.now, 'method': method,
            'detail': {k: params.get(k) for k in ('reason', 'command', 'cwd') if params.get(k)}})
        return self._decline_request(method)

    async def _run_turn(self, task_id, thread_id, prompt, **kwargs):
        record = {'at_seconds': self.meeting_clock.now, 'thread_id': thread_id, 'token_usage': None}
        self.timeline['turns'].append(record); self.current_turn = record
        started = time.monotonic()
        try:
            await super()._run_turn(task_id, thread_id, prompt, **kwargs)
        finally:
            record.update(status=self.store.task(task_id)['status'], elapsed_seconds=time.monotonic()-started,
                          completed_at_seconds=self.meeting_clock.now)

    async def _handle_event(self, task_id, method, params):
        if method == 'thread/tokenUsage/updated' and self.current_turn is not None:
            usage = params.get('tokenUsage', {}); total = usage.get('total', {})
            delta = {k: v-self.token_total.get(k, 0) for k,v in total.items() if isinstance(v, (int,float))}
            self.current_turn['token_usage'] = {k: (self.current_turn['token_usage'] or {}).get(k,0)+v for k,v in delta.items()}
            self.token_total = total.copy()
        await super()._handle_event(task_id, method, params)


async def replay(context, out, *, speed=1, offline=False):
    store = AssistantStore(out/'store')
    timeline = {'offline': offline, 'cache_id': context['cache_id'], 'source': context['source'],
                'store': str(store.directory), 'says': [], 'tools': [], 'turns': [], 'errors': []}
    service = ReplayService(store, Path.home(), context=context, timeline=timeline, speed=speed, fake=offline,
                            output_root=out/'work-output', runtime_factory=OfflineRuntime if offline else CodexRuntime)
    try:
        bound = await service.bind('replay', {k: context[k] for k in ('cache_id', 'session_id', 'title')})
        workspace = bound['workspace_id']
        if service.runtime is None: raise RuntimeError(service.runtime_message)
        await service.cmd_context(workspace, {**context, 'segments': [], 'meeting_state': 'recording'})
        await service.cmd_proactive(workspace, {'enabled': True})
        while True:
            await asyncio.sleep(.001 if offline else .1)
            row = service._conversation(workspace)
            if row['status'] in ('failed','interrupted'): raise RuntimeError(row['error'])
            if service.meeting_clock.ended and not service.task_workers: break
        timeline['final_state'] = await service._snapshot(workspace, announce=False)
        timeline['work'] = [{'title': r['title'], 'goal': r['goal'], 'status': r['status'], 'error': r['error'],
                             'started_at_seconds': service.work_started.get(r['id']),
                             'results': [m['text'] for m in store.messages(workspace) if m['task_id'] == r['id'] and m['role'] == 'assistant']}
                            for r in store.tasks(workspace) if r['kind'] == 'work']
        timeline['final_revision'] = service.meeting_clock.revision
        timeline['completed'] = True
    except (Exception, asyncio.CancelledError) as exc:
        timeline['errors'].append({'error': str(exc) or type(exc).__name__})
    finally:
        await service.shutdown(); store.close()
        (out/'timeline.json').write_text(json.dumps(timeline,ensure_ascii=False,indent=2))
        lines = ['# 旁听助理重放', '', '离线假运行时' if offline else '真实模型', '']
        for row in timeline['says']:
            lines += [f"## {row['at_seconds']:.3f}s", '', row['text'], '']
            lines += ['> '+s['speaker']+'：'+s['text'] for s in row['context']]
        for row in timeline.get('work', []):
            lines += ['', f"## 后台任务 · {row['title']}（{row['status']}，开始于 {row['started_at_seconds'] or 0:.0f}s）", '', row['goal'], '']
            lines += [text for text in row['results']]
        (out/'timeline.md').write_text('\n'.join(lines)+'\n')
    return timeline


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-id', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--speed', type=float, default=1)
    parser.add_argument('--offline', action='store_true')
    args=parser.parse_args(argv)
    if not math.isfinite(args.speed) or args.speed <= 0: parser.error('--speed 必须为有限正数')
    out=args.out.expanduser().resolve(); runtime=(ROOT/'.runtime').resolve()
    if not out.is_relative_to(runtime) or out == runtime: parser.error('--out 必须在项目 .runtime 子目录')
    if out.exists() and any(out.iterdir()): parser.error('--out 必须为空目录或尚不存在')
    out.mkdir(parents=True,exist_ok=True)
    try:
        context=load_context(args.cache_id,out)
        result=asyncio.run(replay(context,out,speed=args.speed,offline=args.offline))
    except Exception as exc:
        result={'errors':[{'error':str(exc)}]}
        (out/'timeline.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps({'timeline':str(out/'timeline.json'),'says':len(result.get('says',[])),
                      'turns':len(result.get('turns',[])),'errors':result['errors']},ensure_ascii=False))
    return int(bool(result['errors']))

if __name__=='__main__': raise SystemExit(main())
