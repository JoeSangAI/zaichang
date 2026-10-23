import copy
import unittest
from adapter import Meeting, render


def ev(kind="segment", at=1, eid="e1", **kw):
    base = {"meeting": "demo", "source": "synthetic", "event_id": eid,
            "received_at": at, "type": kind}
    if kind == "segment":
        base.update(segment_id="s1", revision=1, source_seq=1, start=0, end=1,
                    text="同比12.5%", final=False, speaker={"basis": "unknown"})
    return dict(base, **kw)


class Contract(unittest.TestCase):
    def setUp(self):
        self.m = Meeting("demo")

    def test_revision_replaces_and_final_excludes_pending(self):
        self.m.apply(ev())
        self.assertEqual(self.m.snapshot(1)["whole_meeting"], [])
        self.m.apply(ev(at=2, eid="e2", revision=2, source_seq=2, text="同比15.2%", final=True))
        state = self.m.snapshot(2)
        self.assertEqual(len(state["whole_meeting"]), 1)
        self.assertEqual(state["whole_meeting"][0]["text"], "同比15.2%")
        self.assertEqual(state["pending_segments"], [])

    def test_duplicate_conflicting_event_id(self):
        first = ev()
        self.m.apply(first)
        self.assertEqual(self.m.apply(first), "duplicate")
        with self.assertRaises(ValueError):
            self.m.apply(dict(first, text="不同正文"))

    def test_revision_conflict_and_stale_do_not_overwrite(self):
        self.m.apply(ev(revision=3))
        self.assertEqual(self.m.apply(ev(at=2, eid="e2", revision=2, text="旧正文", source_seq=2)), "stale_revision")
        with self.assertRaises(ValueError):
            self.m.apply(ev(at=3, eid="e3", revision=3, text="冲突", source_seq=3))
        self.assertEqual(self.m.segments["s1"]["text"], "同比12.5%")

    def test_gap_survives_heartbeat_and_backfill_recovers(self):
        self.m.apply(ev(source_seq=3))
        self.assertEqual(self.m.snapshot(1)["missing_source_sequences"], [1, 2])
        self.m.apply(ev("heartbeat", 2, "h"))
        self.assertEqual(self.m.snapshot(2)["health"], "gap")
        self.m.apply(ev(at=3, eid="b1", source_seq=1, segment_id="s0"))
        self.m.apply(ev(at=4, eid="b2", source_seq=2, segment_id="s00"))
        self.assertEqual(self.m.snapshot(4)["health"], "live")

    def test_disconnect_recovery_and_stop(self):
        self.m.apply(ev())
        self.assertEqual(self.m.snapshot(17)["health"], "disconnected")
        self.m.apply(ev("heartbeat", 18, "h"))
        self.assertEqual(self.m.snapshot(18)["health"], "live")
        self.m.apply(ev("stop", 19, "stop"))
        self.assertEqual(self.m.snapshot(50)["health"], "stopped")
        with self.assertRaises(ValueError):
            self.m.apply(ev("heartbeat", 51, "h2"))

    def test_unknown_identity_not_inferred_from_name(self):
        self.m.apply(ev(speaker={"basis": "unknown", "label": "张三"}, text="我是张三"))
        self.assertIn("未知说话人：我是张三", render(self.m.snapshot(1)))
        with self.assertRaises(ValueError):
            self.m.apply(ev(at=2, eid="e2", speaker={"basis": "inferred", "label": "张三"}))

    def request(self, at=1, rid="r1", expiry=10):
        return ev("research_request", at, rid, request_id=rid, query="财报", expires_at=expiry,
                  authorization="user_asked")

    def result(self, at=2, rid="r1"):
        return ev("research_result", at, "result"+rid, request_id=rid, text="带来源的研究",
                  sources=["https://example.com/synthetic-evidence"])

    def test_research_requires_explicit_intent(self):
        with self.assertRaises(ValueError):
            self.m.apply(dict(self.request(), authorization="automatic"))
        self.assertEqual(self.m.requests, {})

    def test_result_stale_after_topic_change(self):
        self.m.apply(self.request())
        self.m.apply(ev("topic", 2, "topic", title="VOC"))
        self.m.apply(self.result(3))
        state = self.m.snapshot(3)
        self.assertEqual(state["research_current"], [])
        self.assertEqual(state["research"][0]["status"], "stale_for_current_topic")

    def test_ready_result_expires_and_not_source_liveness(self):
        self.m.apply(ev("heartbeat", 0, "h"))
        self.m.apply(self.request(expiry=30))
        self.m.apply(self.result(20))
        self.assertEqual(self.m.snapshot(20)["health"], "disconnected")
        self.assertEqual(len(self.m.snapshot(20)["research_current"]), 1)
        self.assertEqual(self.m.snapshot(31)["research_current"], [])
        with self.assertRaises(ValueError):
            self.m.apply(self.result(32))

    def test_invalid_atomic(self):
        before = copy.deepcopy(self.m.__dict__)
        for bad in [ev(source_seq=20000), ev(end=-1), ev(received_at=float("nan")), ev(final="true")]:
            with self.assertRaises(ValueError):
                self.m.apply(bad)
            self.assertEqual(before, self.m.__dict__)

    def test_cross_meeting_and_monotonic_clock(self):
        with self.assertRaises(ValueError):
            self.m.apply(ev(meeting="other"))
        self.m.apply(ev("topic", 10, "t", title="广告"))
        with self.assertRaises(ValueError):
            self.m.apply(ev(at=9))

    def test_recent_window_preserves_full_stable_history(self):
        self.m.apply(ev(final=True))
        self.m.apply(ev(at=2, eid="e2", source_seq=2, segment_id="s2", start=400, end=401, final=True))
        state = self.m.snapshot(2)
        self.assertEqual(len(state["whole_meeting"]), 2)
        self.assertEqual(len(state["current_window"]), 1)

    def test_tick_reports_disconnect_without_source_heartbeat(self):
        self.m.apply(ev())
        self.m.apply(ev("tick", 20, "tick"))
        self.assertEqual(self.m.snapshot(20)["health"], "disconnected")

    def test_background_provenance_does_not_rewrite_transcript(self):
        self.m.apply(ev())
        ctx = ev("context", 2, "context", context_id="project", authorization="user_selected",
                 text="合成项目背景：目标15.2%", reference="synthetic/project-brief", as_of="2026-10-01")
        self.m.apply(ctx)
        state = self.m.snapshot(2)
        self.assertEqual(state["current_window"][0]["text"], "同比12.5%")
        self.assertEqual(state["project_context"]["project"]["as_of"], "2026-10-01")


if __name__ == "__main__":
    unittest.main(verbosity=2)
