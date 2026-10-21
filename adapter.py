"""Offline meeting state adapter. No audio, network, accounts or background jobs."""
import argparse
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path


def number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(f"invalid {name}")
    return value


@dataclass
class Meeting:
    meeting: str
    source: str = "synthetic"
    segments: dict = field(default_factory=dict)
    events: dict = field(default_factory=dict)
    last_at: float | None = None
    event_at: float | None = None
    last_seq: int = 0
    missing: set = field(default_factory=set)
    topic: str = "未指定"
    topic_epoch: int = 0
    requests: dict = field(default_factory=dict)
    results: list = field(default_factory=list)
    context: dict = field(default_factory=dict)
    stopped: bool = False

    def apply(self, event):
        # Validate entirely before committing; malformed events never mark dedup or liveness.
        if event.get("meeting") != self.meeting or event.get("source") != self.source:
            raise ValueError("meeting/source mismatch")
        eid = event.get("event_id")
        if not isinstance(eid, str) or not eid:
            raise ValueError("event_id required")
        canonical = json.dumps(event, ensure_ascii=False, sort_keys=True)
        if eid in self.events:
            if self.events[eid] != canonical:
                raise ValueError("event_id reused with different payload")
            return "duplicate"
        if self.stopped:
            raise ValueError("meeting stopped")
        at = number(event.get("received_at"), "received_at")
        if self.event_at is not None and at < self.event_at:
            raise ValueError("received_at must be monotonic")
        kind = event.get("type")
        status = "accepted"
        if kind == "segment":
            sid = event.get("segment_id")
            rev = event.get("revision")
            seq = event.get("source_seq")
            if not isinstance(sid, str) or not sid:
                raise ValueError("segment_id required")
            for name, val in (("revision", rev), ("source_seq", seq)):
                if type(val) is not int or val < 1:
                    raise ValueError(f"invalid {name}")
            if seq - self.last_seq > 10000:
                raise ValueError("sequence gap exceeds contract limit")
            start = number(event.get("start"), "start")
            end = number(event.get("end"), "end")
            if end < start or not isinstance(event.get("text"), str) or type(event.get("final")) is not bool:
                raise ValueError("invalid segment")
            speaker = event.get("speaker", {})
            if not isinstance(speaker, dict):
                raise ValueError("invalid speaker")
            basis = speaker.get("basis", "unknown")
            if basis not in {"unknown", "channel", "anonymous_cluster", "platform", "human_confirmed", "multiple"}:
                raise ValueError("unsupported identity basis")
            if basis != "unknown" and not isinstance(speaker.get("label"), str):
                raise ValueError("speaker label required")
            old = self.segments.get(sid)
            if old and rev == old["revision"]:
                # Ignore transport fields when identifying a same revision retry.
                fields = ("text", "start", "end", "final", "speaker")
                if any(event.get(k, {}) != old.get(k, {}) for k in fields):
                    raise ValueError("conflicting segment revision")
                status = "same_revision"
            elif old and rev < old["revision"]:
                status = "stale_revision"
            else:
                self.segments[sid] = dict(event)
            if seq > self.last_seq + 1:
                # source_seq must count transcript deliveries, not unrelated platform events.
                self.missing.update(range(self.last_seq + 1, seq))
            self.missing.discard(seq)
            self.last_seq = max(seq, self.last_seq)
        elif kind == "topic":
            if not isinstance(event.get("title"), str) or not event["title"].strip():
                raise ValueError("topic title required")
            if event["title"] != self.topic:
                self.topic = event["title"]
                self.topic_epoch += 1
        elif kind == "context":
            if event.get("authorization") != "user_selected":
                raise ValueError("context must be user selected")
            cid = event.get("context_id")
            if not isinstance(cid, str) or not cid or not all(isinstance(event.get(k), str) and event[k] for k in ("text", "reference", "as_of")):
                raise ValueError("source-backed context required")
            self.context[cid] = {k: event[k] for k in ("text", "reference", "as_of")}
        elif kind == "research_request":
            rid = event.get("request_id")
            if not isinstance(rid, str) or not rid or rid in self.requests:
                raise ValueError("new request_id required")
            if event.get("authorization") not in {"user_asked", "user_accepted_suggestion"}:
                raise ValueError("research requires explicit user intent")
            deadline = number(event.get("expires_at"), "expires_at")
            if deadline <= at or not isinstance(event.get("query"), str):
                raise ValueError("invalid research request")
            self.requests[rid] = {"query": event["query"], "expires_at": deadline,
                                  "topic_epoch": self.topic_epoch, "consumed": False}
        elif kind == "research_result":
            rid = event.get("request_id")
            req = self.requests.get(rid)
            if not req or req["consumed"]:
                raise ValueError("unknown or completed research request")
            if not isinstance(event.get("text"), str) or not isinstance(event.get("sources"), list) or not event["sources"]:
                raise ValueError("source-backed research required")
            if not all(isinstance(s, str) and s.startswith("https://") for s in event["sources"]):
                raise ValueError("invalid research sources")
            stale = at > req["expires_at"] or req["topic_epoch"] != self.topic_epoch
            self.results.append({"request_id": rid, "text": event["text"], "sources": event["sources"],
                                 "status": "stale_for_current_topic" if stale else "ready"})
            req["consumed"] = True
        elif kind == "stop":
            self.stopped = True
        elif kind not in {"heartbeat", "tick"}:
            raise ValueError("unsupported event type")
        self.events[eid] = canonical
        self.event_at = at
        # Research delivery is not transcript liveness.
        if kind in {"segment", "heartbeat", "stop"}:
            self.last_at = at
        return status

    def snapshot(self, now, timeout=15, recent_seconds=180):
        number(now, "now")
        if self.last_at is not None and now < self.last_at:
            raise ValueError("now predates source receipt")
        lag = None if self.last_at is None else now - self.last_at
        health = "stopped" if self.stopped else "waiting" if lag is None else "disconnected" if lag > timeout else "gap" if self.missing else "live"
        ordered = sorted(self.segments.values(), key=lambda s: (s["start"], s["segment_id"]))
        final = [s for s in ordered if s["final"]]
        max_end = max((s["end"] for s in ordered), default=0)
        recent = [s for s in ordered if s["end"] >= max_end - recent_seconds]
        return {"meeting": self.meeting, "source": self.source, "synthetic": self.source == "synthetic",
                "health": health, "last_received_at": self.last_at, "age_seconds": lag,
                "missing_source_sequences": sorted(self.missing), "current_topic": self.topic,
                "topic_epoch": self.topic_epoch, "whole_meeting": final, "current_window": recent,
                "project_context": self.context,
                "pending_segments": [s for s in ordered if not s["final"]],
                "research": self.results,
                "research_current": [r for r in self.results if r["status"] == "ready" and
                                     self.requests[r["request_id"]]["topic_epoch"] == self.topic_epoch and
                                     now <= self.requests[r["request_id"]]["expires_at"]]}


def render(state):
    lines = ["# 会议状态（合成验证）" if state["synthetic"] else "# 会议状态",
             f"来源：{state['source']}；连接：{state['health']}；最后收到：{state['last_received_at']}",
             f"缺失序号：{state['missing_source_sequences']}", f"当前话题：{state['current_topic']}"]
    for key, title in (("whole_meeting", "全场句末结果原文"), ("current_window", "当前窗口（含暂定结果）")):
        lines += ["", "## " + title]
        for s in state[key]:
            speaker = s.get("speaker", {})
            label = "未知说话人" if speaker.get("basis", "unknown") == "unknown" else speaker["label"]
            lines.append(f"- [{s['start']}–{s['end']}] {label}：{s['text']}" + ("（待稳定）" if not s["final"] else ""))
    lines += ["", "## 当前可用研究"]
    lines += [r["text"] + "\n" + "\n".join(r["sources"]) for r in state["research_current"]]
    lines += ["", "## 已选长期背景（不改写原文）"]
    lines += [f"{c['text']}\n来源：{c['reference']}；资料日期：{c['as_of']}" for c in state["project_context"].values()]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="JSONL file or - for stdin")
    parser.add_argument("--meeting", required=True)
    parser.add_argument("--source", default="synthetic")
    parser.add_argument("--now", type=float, required=True, help="same clock as received_at")
    parser.add_argument("--markdown", action="store_true")
    parser.add_argument("--watch", action="store_true", help="emit JSON snapshot after each input event")
    args = parser.parse_args()
    state = Meeting(args.meeting, args.source)
    stream = sys.stdin if args.input == "-" else Path(args.input).open()
    try:
        for index, line in enumerate(stream, 1):
            if line.strip():
                try:
                    event = json.loads(line)
                    state.apply(event)
                    if args.watch:
                        clock = max(event["received_at"], state.event_at or 0)
                        print(json.dumps(state.snapshot(clock), ensure_ascii=False), flush=True)
                except (ValueError, TypeError) as exc:
                    raise ValueError(f"line {index}: {exc}") from exc
        snapshot = state.snapshot(args.now)
        print(render(snapshot) if args.markdown else json.dumps(snapshot, ensure_ascii=False, indent=None if args.watch else 2))
    finally:
        if stream is not sys.stdin:
            stream.close()


if __name__ == "__main__":
    main()
