import unittest
from dual_track import DualTrack


def segment(seq=1, **kw):
    return dict({"session": "demo", "application": "selected-app", "type": "segment",
                 "event_id": "e" + str(seq), "segment_id": "s", "source_seq": seq,
                 "revision": seq, "received_at": seq, "start": 0, "end": 1,
                 "text": "合成测试", "final": True}, **kw)


class DualContract(unittest.TestCase):
    def setUp(self):
        self.d = DualTrack("demo", "selected-app")
        self.d.start(user_confirmed=True)

    def test_no_automatic_or_real_capture(self):
        x = DualTrack("demo", "selected-app")
        for args in [{}, {"user_confirmed": True, "mode": "real"}]:
            with self.assertRaises(ValueError): x.start(**args)
        with self.assertRaises(ValueError): x.ingest("mic", segment())

    def test_per_track_ids_sequences_and_gaps(self):
        self.d.ingest("mic", segment())
        self.d.ingest("remote", segment(3))
        s = self.d.snapshot(3)
        self.assertEqual(s["missing_sequences"], {"mic": [], "remote": [1, 2]})
        self.assertEqual(len(s["whole_meeting"]), 2)
        self.d.ingest("remote", segment(1, event_id="b1", received_at=4, segment_id="back1"))
        self.d.ingest("remote", segment(2, event_id="b2", received_at=5, segment_id="back2"))
        self.assertEqual(self.d.snapshot(5)["missing_sequences"]["remote"], [])

    def test_no_names_inferred_from_audio_or_cluster(self):
        self.d.ingest("mic", segment(speaker={"basis": "human_confirmed", "label": "说话人乙"}))
        self.d.ingest("remote", segment(cluster_id="A", text="我是虚构姓名甲", overlap=True))
        s = self.d.snapshot(1)["whole_meeting"]
        self.assertEqual(s[0]["speaker"]["label"], "本地麦克风")
        self.assertEqual(s[1]["speaker"]["basis"], "anonymous_cluster")
        self.assertTrue(s[1]["overlap"])
        with self.assertRaises(ValueError): self.d.confirm_name("remote", "A", "虚构姓名甲")
        self.d.confirm_name("remote", "A", "虚构姓名甲", confirmed=True, evidence="用户确认该匿名组")
        self.assertEqual(self.d.snapshot(1)["whole_meeting"][1]["speaker"]["basis"], "human_confirmed")

    def test_wrong_session_app_and_bad_input_atomic(self):
        for e in [segment(session="other"), segment(application="other-app"), segment(overlap="yes")]:
            with self.assertRaises(ValueError): self.d.ingest("remote", e)
        self.assertEqual(self.d.snapshot(1)["whole_meeting"], [])

    def test_revisions_pending_and_clock_alignment(self):
        d = DualTrack("demo", "selected-app", {"mic": 0, "remote": 10})
        d.start(user_confirmed=True)
        d.ingest("remote", segment(final=False))
        self.assertEqual(d.snapshot(1)["current_window"][0]["start"], 10)
        d.ingest("remote", segment(2, text="修订后"))
        self.assertEqual(len(d.snapshot(2)["whole_meeting"]), 1)
        self.assertEqual(d.snapshot(2)["pending_segments"], [])

    def test_disconnected_track_not_hidden_by_other(self):
        self.d.ingest("mic", segment())
        self.d.ingest("remote", segment(received_at=20))
        s=self.d.snapshot(20)
        self.assertEqual(s["track_health"], {"mic": "disconnected", "remote": "live"})

    def test_shared_topic_context_and_expiring_research(self):
        self.d.apply_control({"event_id": "t", "type": "topic", "received_at": 0, "title": "财报"})
        self.d.apply_control({"event_id": "c", "type": "context", "received_at": 1,
                              "context_id": "project", "authorization": "user_selected", "text": "已选合成背景",
                              "reference": "synthetic/project", "as_of": "2026-10-02"})
        self.d.apply_control({"event_id": "r", "type": "research_request", "received_at": 2,
                              "request_id": "r", "authorization": "user_asked", "query": "财报", "expires_at": 10})
        self.d.apply_control({"event_id": "answer", "type": "research_result", "received_at": 3,
                              "request_id": "r", "text": "合成结果", "sources": ["https://example.com"]})
        self.assertEqual(len(self.d.snapshot(3)["research_current"]), 1)
        self.assertEqual(self.d.snapshot(11)["research_current"], [])

    def test_stop_forget_and_mapping_not_reused(self):
        self.d.ingest("remote", segment(cluster_id="A"))
        self.d.confirm_name("remote", "A", "某人", confirmed=True, evidence="合成确认")
        self.d.stop(2)
        with self.assertRaises(ValueError): self.d.ingest("mic", segment(3))
        with self.assertRaises(ValueError): self.d.start(user_confirmed=True)
        self.d.forget()
        self.assertEqual(self.d.snapshot(3)["whole_meeting"], [])
        self.assertEqual(self.d.names, {})

    def test_stopped_context_invalid_history_retained(self):
        self.d.ingest('mic',segment())
        self.d.stop(2)
        state=self.d.snapshot(2)
        self.assertFalse(state['live_context_valid'])
        self.assertEqual(state['current_window'],[])
        self.assertEqual(state['research_current'],[])
        self.assertEqual(len(state['whole_meeting']),1)

    def test_capture_track_disconnect_invalidates_live_context(self):
        d=DualTrack('demo','selected-app',source_kind='capture-asr')
        d.start(user_confirmed=True)
        d.ingest('mic',segment()); d.ingest('remote',segment())
        self.assertTrue(d.snapshot(1)['live_context_valid'])
        d.ingest('mic',segment(20))
        self.assertFalse(d.snapshot(20)['live_context_valid'])
        self.assertEqual(d.snapshot(20)['current_window'],[])

    def test_silent_current_window_and_atomic_stop(self):
        self.d.ingest("mic", segment())
        self.assertEqual(self.d.snapshot(200)["current_window"], [])
        self.assertEqual(len(self.d.snapshot(200)["whole_meeting"]), 1)
        self.d.apply_control({"event_id": "t", "type": "topic", "received_at": 5, "title": "VOC"})
        with self.assertRaises(ValueError): self.d.stop(3)
        self.assertFalse(self.d.tracks["mic"].stopped)
        self.assertFalse(self.d.closed)


if __name__ == "__main__": unittest.main()
