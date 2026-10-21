"""Dual-track text bridge with synthetic and explicit text-only modes. No audio or network."""
from copy import deepcopy
from adapter import Meeting, number


class DualTrack:
    def __init__(self, session, application, offsets=None, source_kind="synthetic"):
        if not session or not application:
            raise ValueError("explicit session and selected application required")
        self.session = session
        self.application = application
        if source_kind not in {"synthetic", "capture-asr"}:
            raise ValueError("unsupported text source")
        self.source_kind = source_kind
        self.offsets = offsets or {"mic": 0, "remote": 0}
        if set(self.offsets) != {"mic", "remote"}:
            raise ValueError("both clock offsets required")
        for value in self.offsets.values():
            number(value, "clock offset")
        self.tracks = {t: Meeting(session, source_kind + ":" + t) for t in self.offsets}
        self.control = Meeting(session, source_kind + ":control")
        self.names = {}
        self.started = False
        self.closed = False

    def start(self, *, user_confirmed=False, mode="synthetic"):
        if mode != "synthetic" and not (mode == "text-only" and self.source_kind == "capture-asr"):
            raise ValueError("prototype cannot capture or upload real audio")
        if not user_confirmed or self.started or self.closed:
            raise ValueError("explicit start confirmation required; no automatic restart")
        self.started = True

    def _active(self):
        if not self.started or self.closed:
            raise ValueError("session is not active")

    def ingest(self, track, event):
        self._active()
        if track not in self.tracks or event.get("session") != self.session:
            raise ValueError("session/track mismatch")
        if event.get("application") != self.application:
            raise ValueError("unselected application rejected")
        e = deepcopy(event)
        e.update(meeting=self.session, source=self.source_kind + ":" + track)
        if e.get("type") == "segment":
            # Preserve each upstream sequence; never manufacture a global sequence.
            sid = e.get("segment_id")
            if not isinstance(sid, str) or not sid:
                raise ValueError("stable upstream segment ID required")
            e["segment_id"] = track + ":" + sid
            e["start"] = number(e.get("start"), "start") + self.offsets[track]
            e["end"] = number(e.get("end"), "end") + self.offsets[track]
            cluster = e.get("cluster_id")
            if cluster is not None and (not isinstance(cluster, str) or not cluster):
                raise ValueError("invalid anonymous cluster")
            # Identity from input is intentionally ignored; mic is a channel, not 说话人乙.
            label = "本地麦克风" if track == "mic" else "远端混音"
            basis = "channel"
            if track == "remote" and cluster:
                label, basis = "远端匿名组 " + cluster, "anonymous_cluster"
            local=e.get('speaker',{})
            if e.get('local_speaker_model')=='nemotron3-low:25a90f97f254428d4b30374b76af9c74fdee8327' and e.get('source_id')==track and isinstance(e.get('epoch'),str) and e['epoch']:
                kind=local.get('basis') if isinstance(local,dict) else None
                if kind=='anonymous_cluster' and type(local.get('cluster_id')) is int and 0<=local['cluster_id']<8 and local.get('source_id')==track and local.get('epoch')==e['epoch']:
                    e['cluster_id']=e['epoch']+':s'+str(local['cluster_id'])
                    e['speaker']={'basis':'anonymous_cluster','label':('麦克风' if track=='mic' else '远端')+'说话人 '+str(local['cluster_id']+1)}
                elif kind=='multiple' and local.get('reason') in {'overlap','speaker_change'}:
                    e['speaker']={'basis':'multiple','label':'多人同时发言' if local['reason']=='overlap' else '句内说话人变化'}
                else:e['speaker']={'basis':'unknown'}
            else:e["speaker"] = {"basis": basis, "label": label}
            e["track"] = track
            if "overlap" in e and type(e["overlap"]) is not bool:
                raise ValueError("invalid overlap marker")
        elif e.get("type") not in {"tick", "heartbeat"}:
            raise ValueError("use control channel for non-ASR events")
        return self.tracks[track].apply(e)

    def apply_control(self, event):
        self._active()
        if event.get("type") not in {"topic", "context", "research_request", "research_result", "tick"}:
            raise ValueError("invalid control event")
        return self.control.apply(dict(event, meeting=self.session, source=self.source_kind + ":control"))

    def confirm_name(self, track, cluster, name, *, confirmed=False, evidence=""):
        self._active()
        if track not in self.tracks or not confirmed or not evidence.strip() or not name.strip():
            raise ValueError("name mapping requires explicit confirmation and evidence")
        if track == "remote" and not any(s.get("cluster_id") == cluster for s in self.tracks[track].segments.values()):
            raise ValueError("cluster has not been observed in this session")
        if track == "mic" and cluster is not None:
            raise ValueError("mic channel does not provide clusters")
        self.names[(track, cluster)] = {"name": name, "evidence": evidence}

    def snapshot(self, now, recent_seconds=180):
        views = {t: m.snapshot(now) for t, m in self.tracks.items()}
        segments = sorted((deepcopy(s) for v in views.values() for s in v["whole_meeting"] + v["pending_segments"]),
                          key=lambda s: (s["start"], s["segment_id"]))
        for s in segments:
            mapping = self.names.get((s["track"], s.get("cluster_id")))
            if mapping:
                s["speaker"] = {"basis": "human_confirmed", "label": mapping["name"], "evidence": mapping["evidence"]}
        control = self.control.snapshot(now)
        context_valid = not self.closed and (self.source_kind == "synthetic" or all(v["health"] == "live" for v in views.values()))
        edge = max(now, max((s["end"] for s in segments), default=0))
        return {"session": self.session, "application": self.application, "synthetic": self.source_kind == "synthetic",
                "lifecycle": "stopped" if self.closed else "active" if self.started else "idle",
                "track_health": {t: v["health"] for t, v in views.items()},
                "missing_sequences": {t: v["missing_source_sequences"] for t, v in views.items()},
                "whole_meeting": [s for s in segments if s["final"]],
                "live_context_valid": context_valid,
                "current_window": [s for s in segments if s["end"] >= edge - recent_seconds] if context_valid else [],
                "pending_segments": [s for s in segments if not s["final"]],
                "current_topic": control["current_topic"] if context_valid else "采集已停止或覆盖不完整，当前话题无效", "project_context": control["project_context"],
                "research_current": control["research_current"] if context_valid else [],
                "coverage": "local delivery sequences only; audio loss and diarization quality unverified"}

    def stop(self, at):
        self._active()
        # Validate all clocks before stopping any part.
        for m in [*self.tracks.values(), self.control]:
            m.snapshot(at)
            if m.event_at is not None and at < m.event_at:
                raise ValueError("stop predates an accepted event")
        for m in [*self.tracks.values(), self.control]:
            m.apply({"meeting": self.session, "source": m.source, "type": "stop",
                     "event_id": "session-stop", "received_at": at})
        self.closed = True

    def forget(self):
        if not self.closed:
            raise ValueError("stop before discarding in-memory data")
        self.tracks = {t: Meeting(self.session, self.source_kind + ":" + t) for t in self.offsets}
        self.control = Meeting(self.session, self.source_kind + ":control")
        self.names.clear()
