import json
import os
import contextlib
import io
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

import meeting_context as mc


def turn(text, *, speaker="发言人 1", confirmed=False, final=True, start=0.0, source="麦克风"):
    return {
        "id": f"turn-{start}", "parent": f"parent-{start}", "text": text,
        "speaker": speaker, "speaker_confirmed": confirmed, "uncertain": False,
        "final": final, "start": start, "end": start + 1.0,
        "absolute_start": "2026-10-05T10:00:00+08:00", "absolute_end": None,
        "source": source,
        "parts": [{"id": "part-1", "text": text, "speaker": speaker,
                   "speaker_confirmed": confirmed, "start": start, "end": start + 1.0}],
        # Must never be returned to an Agent.
        "embedding": [0.1, 0.2], "raw_audio_path": "/private/audio.wav",
    }


def linked_turn(text="确认的合成会议文字", *, start=0.0):
    value = turn(text, speaker="合成人物", confirmed=True, start=start)
    for row in [value, *value["parts"]]:
        row.update(speaker_name_origin="manual", shared_person_id="person:0123456789abcdef0123",
                   shared_person_evidence=["/合成资料/人员主档.md:12"])
    return value


class MeetingContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = Path(self.temp.name) / "context.sqlite"
        self.writer = sqlite3.connect(self.db)
        self.writer.execute("PRAGMA journal_mode=WAL")
        self.writer.executescript("""
            PRAGMA user_version=1;
            CREATE TABLE state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE meetings(session TEXT PRIMARY KEY,metadata TEXT NOT NULL,revision INTEGER NOT NULL);
            CREATE TABLE segments(
              session TEXT,parent TEXT,revision INTEGER NOT NULL,start REAL NOT NULL,end REAL,
              payload TEXT NOT NULL,updated_revision INTEGER NOT NULL,deleted INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY(session,parent));
            CREATE INDEX segments_session_start_parent ON segments(session,start,parent);
            CREATE INDEX segments_session_updated_revision ON segments(session,updated_revision);
        """)
        self.writer.commit()

    def test_archive_snapshot_is_complete_and_blocks_unsettled_sources(self):
        self.meeting("s-live", phase="paused")
        metadata = json.loads(self.writer.execute("SELECT metadata FROM meetings").fetchone()[0])
        metadata["transcription_complete"] = True
        self.writer.execute("UPDATE meetings SET metadata=?", (json.dumps(metadata),))
        self.writer.commit()
        for i in range(130):
            self.segment("s-live", str(i), start=i, payload=[turn("完整长原文" * 100, start=i)])
        reader = mc.Reader(self.db)
        try:
            result = reader.archive_snapshot("s-live")
            self.assertEqual(len(json.loads(result["text"])), 130)
            self.assertGreater(len(result["text"]), mc.MAX_OUTPUT_CHARS)
            self.assertNotIn("raw_audio_path", result["text"])
        finally:
            reader.close()
        for field, value in (("phase", "recording"), ("projection_updating", True), ("transcription_complete", False), ("local_only", True)):
            changed = dict(metadata, **{field: value})
            self.writer.execute("UPDATE meetings SET metadata=?", (json.dumps(changed),))
            self.writer.commit()
            reader = mc.Reader(self.db)
            try:
                with self.assertRaises(mc.ContextError):
                    reader.archive_snapshot("s-live")
            finally:
                reader.close()

    def test_settled_archive_preserves_nonfinal_words_without_promoting_them(self):
        self.meeting("s-live", phase="stopped")
        metadata = json.loads(self.writer.execute("SELECT metadata FROM meetings").fetchone()[0])
        metadata["transcription_complete"] = True
        self.writer.execute("UPDATE meetings SET metadata=?", (json.dumps(metadata),))
        self.writer.commit()
        self.segment("s-live", "confirmed", start=1, payload=[turn("已确认完整句", start=1)])
        self.segment("s-live", "partial", start=2, payload=[turn("预算可能是五", final=False, start=2)])
        before = self.writer.execute("SELECT payload FROM segments ORDER BY parent").fetchall()
        reader = mc.Reader(self.db)
        try:
            result = reader.archive_snapshot("s-live")
            turns = [t for r in json.loads(result["text"]) for t in r["turns"]]
            self.assertEqual([t["text"] for t in turns], ["已确认完整句", "预算可能是五"])
            self.assertEqual([t["final"] for t in turns], [True, False])
            self.assertEqual(result["uncertainty"]["nonfinal_turn_ids"], ["turn-2"])
            self.assertEqual(result["uncertainty"]["final_turn_count"], 1)
            self.assertTrue(result["complete"])
            self.assertEqual(before, self.writer.execute("SELECT payload FROM segments ORDER BY parent").fetchall())
        finally:
            reader.close()

    def test_symbol_topic_does_not_block_current(self):
        self.meeting("s-live"); self.state(); self.segment("s-live", "one", start=1)
        reader=mc.Reader(self.db)
        try:
            self.assertEqual(reader.current("❓？？？")["status"], "ok")
            coverage=reader.search("s-live", "财报")["coverage"]
            self.assertEqual(coverage["meeting_total_rows"], 1)
            self.assertEqual(coverage["scope"], "bounded_search_matches_and_neighbors")
        finally: reader.close()

    def test_recovery_provenance_preserves_gap_warning_without_audio_paths(self):
        value = mc._safe_metadata({"recording_recovery": {
            "kind": "interrupted_capture", "state": "recovered_unclean_shutdown",
            "audio_files_preserved": True, "gapless_capture_verified": False,
            "transcript_modified": False, "transcription_started": False,
            "audio_path": "/private/raw.pcm", "warnings": ["capture_gap_unknown"],
            "tracks": [{"track": "mic", "before_bytes": 10, "verified_bytes": 12,
                        "verified_tail_bytes": 2, "audio_path": "/private/raw.pcm"}]}})
        recovery = value["recording_recovery"]
        self.assertFalse(recovery["gapless_capture_verified"])
        self.assertEqual(recovery["warnings"], ["capture_gap_unknown"])
        self.assertEqual(recovery["tracks"][0]["verified_tail_bytes"], 2)
        self.assertNotIn("audio_path", json.dumps(value))

    def test_wal_committed_rows_readable_after_writer_crash(self):
        self.meeting("s-live"); self.segment("s-live", "one", start=1)
        code="import sqlite3,sys,os; db=sqlite3.connect(sys.argv[1]); db.execute('PRAGMA journal_mode=WAL'); db.execute(\"UPDATE meetings SET revision=22\"); db.commit(); os._exit(0)"
        subprocess.run([sys.executable,"-c",code,str(self.db)],check=True,timeout=3)
        reader=mc.Reader(self.db)
        try: self.assertEqual(reader.read("s-live")["revision"],22)
        finally: reader.close()

    def tearDown(self):
        self.writer.close()
        self.temp.cleanup()

    def state(self, session="s-live", *, phase="recording", heartbeat=None, pid=None):
        obj = {"schema": 1, "session": session,
               "pid": os.getpid() if pid is None else pid, "writer_id": "writer-a",
               "heartbeat": time.time() if heartbeat is None else heartbeat, "phase": phase}
        self.writer.execute("INSERT OR REPLACE INTO state VALUES('current',?)", (json.dumps(obj),))
        self.writer.commit()

    def meeting(self, session, *, phase="recording", updating=False, revision=1, local_only=False):
        metadata = {"session": session, "title": "策略会议", "phase": phase,
                    "local_only": local_only, "projection_updating": updating,
                    "recording_elapsed_seconds": 20, "updated_at": "2026-10-05T10:00:00+08:00",
                    "writer_id": "writer-a"}
        self.writer.execute("INSERT OR REPLACE INTO meetings VALUES(?,?,?)",
                            (session, json.dumps(metadata, ensure_ascii=False), revision))
        self.writer.commit()

    def segment(self, session, parent, *, start, payload=None, revision=1,
                updated_revision=1, deleted=0, end=None):
        if payload is None:
            payload = [turn("我们刚才讨论了财报", start=start)]
        self.writer.execute(
            "INSERT OR REPLACE INTO segments VALUES(?,?,?,?,?,?,?,?)",
            (session, parent, revision, start, end if end is not None else start + 1,
             json.dumps(payload, ensure_ascii=False), updated_revision, deleted))
        self.writer.commit()

    def reader(self, now=None):
        return mc.Reader(self.db, now=now)

    def test_current_uses_only_explicit_live_state_and_returns_small_meeting(self):
        self.meeting("s-live")
        self.meeting("s-other", phase="paused")
        self.segment("s-live", "p1", start=2, payload=[turn("最新发言", start=2)])
        self.segment("s-other", "p2", start=9, payload=[turn("其他会议", start=9)])
        self.state("s-live")
        reader = self.reader()
        try:
            result = reader.current()
        finally:
            reader.close()
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["session"], "s-live")
        self.assertEqual(result["response_mode"], "live_meeting")
        self.assertEqual([t["text"] for s in result["segments"] for t in s["turns"]], ["最新发言"])
        self.assertEqual(result["advisory"]["first_answer_target_seconds"], 30)
        self.assertNotIn("embedding", json.dumps(result))
        self.assertNotIn("raw_audio_path", json.dumps(result))

    def test_stale_crashed_and_stopped_state_never_falls_back_to_latest_disk_meeting(self):
        self.meeting("cached", phase="paused")
        self.segment("cached", "p1", start=1)
        reader = self.reader()
        try:
            self.assertEqual(reader.current()["status"], "no_current_meeting")
        finally:
            reader.close()
        self.state("cached", heartbeat=time.time() - 11)
        reader = self.reader()
        try:
            result = reader.current()
        finally:
            reader.close()
        self.assertEqual(result["status"], "no_current_meeting")
        self.assertEqual(result["last_session"], "cached")
        self.state("cached", pid=99999999)
        reader = self.reader()
        try:
            self.assertEqual(reader.current()["status"], "no_current_meeting")
        finally:
            reader.close()
        self.state("cached", phase="stopped")
        reader = self.reader()
        try:
            self.assertEqual(reader.current()["status"], "no_current_meeting")
        finally:
            reader.close()

    def test_paused_meeting_is_readable_and_explicit_session_is_pinned(self):
        self.meeting("paused", phase="paused")
        self.meeting("newer", phase="recording")
        self.segment("paused", "p1", start=2)
        self.segment("newer", "p2", start=9)
        self.state("paused", phase="paused")
        reader = self.reader()
        try:
            result = reader.read("paused")
        finally:
            reader.close()
        self.assertEqual(result["response_mode"], "paused")
        self.assertEqual(result["session"], "paused")
        with self.assertRaisesRegex(mc.ContextError, "meeting_not_found"):
            reader = self.reader()
            try:
                reader.read("wrong-meeting")
            finally:
                reader.close()

    def test_manual_shared_identity_round_trips_all_reader_routes(self):
        value = linked_turn()
        self.meeting("s-live"); self.state("s-live")
        self.segment("s-live", "person-link", start=0, payload=[value])
        reader = self.reader()
        try:
            for result in [reader.current(), reader.read("s-live"),
                           reader.search("s-live", "合成"), reader.changes("s-live", 0)]:
                actual = result["segments"][0]["turns"][0]
                for row in [actual, *actual["parts"]]:
                    self.assertEqual(row["shared_person_id"], value["shared_person_id"])
                    self.assertEqual(row["shared_person_evidence"], value["shared_person_evidence"])
                    self.assertNotIn("embedding", row)
            for kind in ["turns", "parts"]:
                token = {"session": "s-live", "parent": "person-link", "parent_revision": 1,
                         "kind": kind, "index": 0, "turn_index": 0}
                row = reader.read("s-live", cursor=mc._encode_cursor(token))["continuation_chunk"]["item"]
                self.assertEqual(row["shared_person_id"], value["shared_person_id"])
                self.assertEqual(row["shared_person_evidence"], value["shared_person_evidence"])
        finally:
            reader.close()

    def test_shared_identity_rejects_automatic_or_unconfirmed_provenance(self):
        for origin, confirmed in [("voiceprint", True), ("semantic", True), ("anonymous", True),
                                  ("manual", False), ("manual", "true"), ("manual", 1)]:
            with self.subTest(origin=origin, confirmed=confirmed):
                value = linked_turn(); value.update(speaker_name_origin=origin, speaker_confirmed=confirmed)
                actual = mc._safe_part(value)
                self.assertNotIn("shared_person_id", actual)
                self.assertNotIn("shared_person_evidence", actual)

    def test_shared_identity_validates_id_and_bounded_source_evidence(self):
        invalid_ids = ["01234567-1234-1234-1234-0123456789ab", "person:0123456789ABCDEF0123",
                       "person:0123", "person:0123456789abcdef0123\n", None, 12]
        invalid_evidence = [[], ["source:1"] * 9, ["a" * 2049], [""], ["   "],
                            ["source\n:1"], ["source\x7f:1"], ["source\x85:1"], ["source\u202e:1"], [None],
                            [{"path": "source"}], "source:1"]
        for person_id in invalid_ids:
            value = linked_turn(); value["shared_person_id"] = person_id
            self.assertNotIn("shared_person_id", mc._safe_part(value))
        for evidence in invalid_evidence:
            value = linked_turn(); value["shared_person_evidence"] = evidence
            actual = mc._safe_part(value)
            self.assertNotIn("shared_person_id", actual)
            self.assertNotIn("shared_person_evidence", actual)
        value = linked_turn(); value["shared_person_evidence"] = ["a" * 2048] * 8
        self.assertEqual(len(mc._safe_part(value)["shared_person_evidence"]), 8)

    def test_turn_identity_requires_every_part_same_manual_person_and_evidence(self):
        for variation in ["missing", "different_person", "different_evidence", "automatic", "uncertain", "empty"]:
            with self.subTest(variation=variation):
                value = linked_turn()
                value["parts"].append(dict(value["parts"][0], id="part-2"))
                second = value["parts"][1]
                if variation == "missing": second.pop("shared_person_id")
                elif variation == "different_person": second["shared_person_id"] = "person:fedcba9876543210abcd"
                elif variation == "different_evidence": second["shared_person_evidence"] = ["/合成资料/另一个来源.md:9"]
                elif variation == "automatic": second["speaker_name_origin"] = "voiceprint"
                elif variation == "uncertain": value["uncertain"] = True
                elif variation == "empty": value["parts"] = []
                actual = mc._safe_turn(value)
                self.assertNotIn("shared_person_id", actual)
                self.assertNotIn("shared_person_evidence", actual)
                if actual["parts"]:
                    self.assertEqual(actual["parts"][0]["shared_person_id"], value["shared_person_id"])

    def test_unlinked_legacy_projection_does_not_gain_identity_fields(self):
        value = mc._safe_turn(turn("旧格式"))
        for row in [value, *value["parts"]]:
            self.assertNotIn("shared_person_id", row)
            self.assertNotIn("shared_person_evidence", row)

    def test_updating_pages_strip_shared_identity_with_stale_names(self):
        self.meeting("s-live", updating=True); self.state("s-live")
        self.segment("s-live", "person-link", start=0, payload=[linked_turn()])
        reader = self.reader()
        try:
            for result in [reader.current(), reader.read("s-live"),
                           reader.search("s-live", "合成"), reader.changes("s-live", 0)]:
                actual = result["segments"][0]["turns"][0]
                self.assertEqual(result["status"], "updating")
                for row in [actual, *actual["parts"]]:
                    self.assertEqual(row["speaker"], "待确认")
                    self.assertNotIn("shared_person_id", row)
                    self.assertNotIn("shared_person_evidence", row)
            for kind in ["turns", "parts"]:
                token = {"session": "s-live", "parent": "person-link", "parent_revision": 1,
                         "kind": kind, "index": 0, "turn_index": 0}
                row = reader.read("s-live", cursor=mc._encode_cursor(token))["continuation_chunk"]["item"]
                for item in [row, *row.get("parts", [])]:
                    self.assertEqual(item["speaker"], "待确认")
                    self.assertNotIn("shared_person_id", item)
                    self.assertNotIn("shared_person_evidence", item)
        finally:
            reader.close()

    def test_automatic_name_origin_reaches_reader_without_confirmation(self):
        row=turn("合成会议文字", speaker="测试人（声音识别）")
        row['speaker_name_origin']='voiceprint'
        row['parts'][0]['speaker_name_origin']='voiceprint'
        self.meeting('auto-name', revision=1)
        self.segment('auto-name','p1',start=0,payload=[row])
        reader=self.reader()
        try:
            result=reader.read('auto-name')
        finally:
            reader.close()
        actual=result['segments'][0]['turns'][0]
        self.assertEqual(actual['speaker_name_origin'],'voiceprint')
        self.assertEqual(actual['parts'][0]['speaker_name_origin'],'voiceprint')
        self.assertFalse(actual['speaker_confirmed'])
        self.assertNotIn('embedding',actual)

    def test_semantic_name_provenance_reaches_reader_without_becoming_confirmed(self):
        row=turn("合成会议文字", speaker="测试人（语义识别）")
        row['speaker_name_origin']='semantic'
        row['parts'][0]['speaker_name_origin']='semantic'
        self.meeting('auto-name', revision=1)
        self.segment('auto-name','p1',start=0,payload=[row])
        reader=self.reader()
        try:
            result=reader.read('auto-name')
        finally:
            reader.close()
        actual=result['segments'][0]['turns'][0]
        self.assertEqual(actual['speaker_name_origin'],'semantic')
        self.assertEqual(actual['parts'][0]['speaker_name_origin'],'semantic')
        self.assertFalse(actual['speaker_confirmed'])
        self.assertNotIn('embedding',actual)

    def test_changes_include_correction_and_deletion_tombstone(self):
        self.meeting("s-live", revision=4)
        self.segment("s-live", "p1", start=1, payload=[turn("更正后的内容", speaker="合成说话人甲", confirmed=True)],
                     revision=2, updated_revision=3)
        self.segment("s-live", "p2", start=2, payload=[], revision=2, updated_revision=4, deleted=1)
        reader = self.reader()
        try:
            result = reader.changes("s-live", after_revision=2)
        finally:
            reader.close()
        self.assertEqual(result["revision"], 4)
        self.assertEqual(result["next_revision"], 4)
        self.assertEqual(len(result["segments"]), 2)
        correction, deletion = result["segments"]
        self.assertEqual(correction["turns"][0]["speaker"], "合成说话人甲")
        self.assertTrue(correction["turns"][0]["speaker_confirmed"])
        self.assertTrue(deletion["deleted"])

    def test_changes_cursor_keeps_same_revision_batch_and_budget_continuable(self):
        self.meeting("s-live", revision=8)
        for i in range(128):
            self.segment("s-live", f"p{i:03d}", start=i,
                         payload=[turn("同一修订批次内容" * 24, start=i)], updated_revision=8)
        reader = self.reader()
        try:
            page = reader.changes("s-live", after_revision=0, limit=120)
            self.assertLessEqual(len(json.dumps(page, ensure_ascii=False, separators=(",", ":"))), mc.MAX_OUTPUT_CHARS)
            received = [row["parent"] for row in page["segments"]]
            cursor = page["next_cursor"]
            self.assertIsNotNone(cursor)
            while cursor:
                page = reader.changes("s-live", after_revision=0, limit=120, cursor=cursor)
                received.extend(row["parent"] for row in page["segments"])
                cursor = page["next_cursor"]
        finally:
            reader.close()
        self.assertEqual(len(received), 128)
        self.assertEqual(len(set(received)), 128)
        self.assertEqual(received, [f"p{i:03d}" for i in range(128)])

    def test_projection_update_is_explicit_and_does_not_present_old_rows_as_current(self):
        self.meeting("s-live", updating=True)
        self.segment("s-live", "p1", start=1)
        self.state("s-live")
        reader = self.reader()
        try:
            result = reader.current()
        finally:
            reader.close()
        self.assertEqual(result["status"], "updating")
        self.assertEqual(len(result["segments"]), 1)
        self.assertFalse(result["speaker_labels_verified"])
        self.assertEqual(result["segments"][0]["turns"][0]["speaker"], "待确认")
        self.assertEqual(result["projection_state"], "committed_text_pending_speaker_projection")
        reader = self.reader()
        try:
            for page in [reader.read("s-live"), reader.search("s-live", "财报"), reader.changes("s-live", 0)]:
                self.assertEqual(page["status"], "updating")
                self.assertEqual(len(page["segments"]), 1)
                self.assertIn("财报", page["segments"][0]["turns"][0]["text"])
                self.assertEqual(page["segments"][0]["turns"][0]["speaker"], "待确认")
        finally:
            reader.close()

    def test_updating_continuations_preserve_words_and_mask_stale_names(self):
        self.meeting("s-live", updating=True)
        self.segment("s-live", "p1", start=1)
        reader = self.reader()
        try:
            for kind in ["turns", "parts"]:
                token = {"session": "s-live", "parent": "p1", "parent_revision": 1,
                         "kind": kind, "index": 0, "turn_index": 0}
                page = reader.read("s-live", cursor=mc._encode_cursor(token))
                self.assertEqual(page["status"], "updating")
                self.assertFalse(page["speaker_labels_verified"])
                item = page["continuation_chunk"]["item"]
                self.assertIn("财报", item["text"])
                for value in [item, *item.get("parts", [])]:
                    self.assertEqual(value["speaker"], "待确认")
                    self.assertFalse(value["speaker_confirmed"])
        finally:
            reader.close()

    def test_current_writer_generation_must_match_meeting_metadata(self):
        self.meeting("s-live")
        self.segment("s-live", "p1", start=1)
        self.state("s-live")
        self.writer.execute("UPDATE meetings SET metadata=? WHERE session='s-live'", (
            json.dumps({"session": "s-live", "title": "旧写入者", "phase": "recording",
                        "local_only": True, "projection_updating": False,
                        "recording_elapsed_seconds": 1, "updated_at": "", "writer_id": "old"}),
        ))
        self.writer.commit()
        reader = self.reader()
        try:
            result = reader.current()
        finally:
            reader.close()
        self.assertEqual(result["status"], "no_current_meeting")
        self.assertNotIn("segments", result)

    def test_current_phase_mismatch_and_local_only_never_return_transcript(self):
        self.meeting("s-live", phase="stopped")
        self.segment("s-live", "p1", start=1)
        self.state("s-live", phase="recording")
        reader = self.reader()
        try:
            self.assertEqual(reader.current()["status"], "no_current_meeting")
        finally:
            reader.close()
        self.meeting("local", phase="recording", local_only=True)
        self.segment("local", "p2", start=2)
        self.state("local", phase="recording")
        reader = self.reader()
        try:
            current = reader.current()
            explicit = reader.read("local")
        finally:
            reader.close()
        self.assertEqual(current["status"], "recording_only")
        self.assertEqual(explicit["status"], "recording_only")
        self.assertEqual(current["segments"], [])
        self.assertEqual(explicit["segments"], [])
        self.meeting("idle", phase="idle")
        self.segment("idle", "p3", start=3)
        reader = self.reader()
        try:
            idle = reader.read("idle")
        finally:
            reader.close()
        self.assertEqual(idle["response_mode"], "history")

    def test_search_preserves_repeated_text_by_different_speakers_and_neighborhood(self):
        self.meeting("s-live")
        self.segment("s-live", "p1", start=1, payload=[turn("开始", speaker="测试人物甲", start=1)])
        self.segment("s-live", "p2", start=5, payload=[turn("示例产品季报", speaker="合成说话人乙", start=5)])
        self.segment("s-live", "p3", start=6, payload=[turn("示例产品季报", speaker="合成说话人甲", start=6)])
        self.segment("s-live", "p4", start=9, payload=[turn("继续讨论", speaker="测试人物甲", start=9)])
        reader = self.reader()
        try:
            result = reader.search("s-live", "示例产品季报", limit=20)
        finally:
            reader.close()
        self.assertEqual([row["parent"] for row in result["segments"]], ["p1", "p2", "p3", "p4"])
        hits = [row for row in result["segments"] if "示例产品" in row["turns"][0]["text"]]
        self.assertEqual({r["turns"][0]["speaker"] for r in hits}, {"合成说话人乙", "合成说话人甲"})

    def test_search_prefers_recent_hits_in_a_long_repeated_topic(self):
        self.meeting("s-live")
        for i in range(80):
            self.segment("s-live", f"p{i:03d}", start=i * 30,
                         payload=[turn(f"主题财报第{i}段", start=i * 30)])
        reader = self.reader()
        try:
            result = reader.search("s-live", "主题财报", limit=5)
        finally:
            reader.close()
        matches = [row["parent"] for row in result["segments"]
                   if "主题财报" in row["turns"][0]["text"]]
        self.assertTrue({"p075", "p076", "p077", "p078", "p079"}.issubset(matches))
        self.assertNotIn("p000", matches)

    def test_wal_reader_keeps_one_snapshot_while_writer_commits(self):
        self.meeting("s-live", revision=1)
        self.segment("s-live", "p1", start=1)
        self.state("s-live")
        reader = self.reader()
        try:
            before, _ = reader._meeting("s-live")
            self.writer.execute("UPDATE meetings SET revision=2 WHERE session='s-live'")
            self.segment("s-live", "p2", start=2)
            self.writer.commit()
            after, revision = reader._meeting("s-live")
            self.assertEqual(revision, 1)
            self.assertEqual(before["session"], after["session"])
            self.assertEqual(reader.read("s-live")["coverage"]["total_rows"], 1)
        finally:
            reader.close()
        fresh = self.reader()
        try:
            self.assertEqual(fresh.read("s-live")["coverage"]["total_rows"], 2)
        finally:
            fresh.close()

    def test_long_meeting_is_bounded_and_fast(self):
        self.meeting("long", revision=50_000)
        rows = []
        for i in range(50_000):
            payload = [turn(f"讨论内容第{i}段", start=float(i))]
            rows.append(("long", f"p{i:05d}", 1, float(i), float(i) + .5,
                         json.dumps(payload, ensure_ascii=False), i + 1, 0))
        self.writer.executemany("INSERT INTO segments VALUES(?,?,?,?,?,?,?,?)", rows)
        self.writer.commit()
        self.state("long")
        started = time.monotonic()
        reader = self.reader()
        try:
            result = reader.current("讨论内容")
        finally:
            reader.close()
        elapsed = time.monotonic() - started
        serialized = json.dumps(result, ensure_ascii=False, separators=(",", ":"))
        self.assertEqual(result["status"], "ok")
        self.assertLessEqual(len(serialized), mc.MAX_OUTPUT_CHARS)
        self.assertTrue(result["coverage"]["truncated"])
        self.assertEqual(result["coverage"]["total_rows"], 50_000)
        self.assertIn("p49999", [row["parent"] for row in result["segments"]])
        self.assertLess(elapsed, mc.DEADLINE_SECONDS)

    def test_50k_cold_cli_first_read_is_bounded(self):
        self.meeting("long", revision=50_000)
        rows = []
        for i in range(50_000):
            payload = [turn(f"冷启动会议内容第{i}段", start=float(i))]
            rows.append(("long", f"p{i:05d}", 1, float(i), float(i) + .5,
                         json.dumps(payload, ensure_ascii=False), i + 1, 0))
        self.writer.executemany("INSERT INTO segments VALUES(?,?,?,?,?,?,?,?)", rows)
        self.writer.commit()
        self.state("long")
        started = time.monotonic()
        proc = subprocess.run(
            [sys.executable, str(Path(mc.__file__).resolve()), "--database", str(self.db),
             "current", "--query", "冷启动会议内容"],
            check=False, capture_output=True, text=True, timeout=mc.DEADLINE_SECONDS + 2)
        elapsed = time.monotonic() - started
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["status"], "ok")
        self.assertLessEqual(len(proc.stdout), mc.MAX_OUTPUT_CHARS)
        self.assertLess(elapsed, mc.DEADLINE_SECONDS)

    def test_oversized_first_parent_returns_partial_marker_and_text_continuation(self):
        self.meeting("s-live")
        original = "长" * 100_000
        huge_turn = turn(original, start=0)
        huge_turn["parts"] = [{"id": "small", "text": "关联片段", "speaker": "发言人 1",
                               "speaker_confirmed": False, "start": 0, "end": 1}]
        self.segment("s-live", "p0", start=0, payload=[huge_turn])
        self.segment("s-live", "p1", start=1, payload=[turn("下一段", start=1)])
        reader = self.reader()
        try:
            result = reader.read("s-live", limit=2)
            self.assertEqual(result["coverage"]["returned_rows"], 1)
            self.assertEqual(result["next_offset"], 1)
            turn_out = result["segments"][0]["turns"][0]
            self.assertTrue(turn_out["text_truncated"])
            self.assertEqual(turn_out["text_total_chars"], len(original))
            cursor = result["continuations"][0]
            chunks = [turn_out["text"]]
            while cursor:
                next_result = reader.read("s-live", cursor=cursor)
                chunks.append(next_result["continuation_chunk"]["text"])
                cursor = next_result["next_cursor"]
        finally:
            reader.close()
        self.assertEqual("".join(chunks), original)

    def test_oversized_turn_array_is_marked_and_all_turns_have_a_cursor(self):
        self.meeting("s-live")
        payload = [turn(f"第{i}句" + "语" * 500, start=float(i)) for i in range(200)]
        self.segment("s-live", "p0", start=0, payload=payload)
        reader = self.reader()
        try:
            result = reader.read("s-live", limit=1)
            out = result["segments"][0]
            self.assertTrue(out["turns_truncated"])
            seen = len(out["turns"])
            cursor = next(value for value in result["continuations"]
                          if mc._decode_cursor(value)["kind"] == "turns")
            while cursor:
                chunk = reader.read("s-live", cursor=cursor)
                self.assertEqual(chunk["continuation_chunk"]["kind"], "turns")
                seen += 1
                cursor = chunk["next_cursor"]
                if chunk.get("continuations"):
                    # Each turn may itself have a text cursor; consume it fully.
                    text_cursor = chunk["continuations"][0]
                    pieces = []
                    while text_cursor:
                        piece = reader.read("s-live", cursor=text_cursor)
                        pieces.append(piece["continuation_chunk"]["text"])
                        text_cursor = piece["next_cursor"]
                    self.assertGreater(len("".join(pieces)), 0)
        finally:
            reader.close()
        self.assertEqual(seen, 200)

    def test_freshness_only_describes_returned_rows_when_output_budget_truncates(self):
        self.meeting("s-live")
        for i in range(12):
            payload = [turn((f"内容{i}" * 1500), start=i)]
            self.segment("s-live", f"p{i:02d}", start=i, end=i + 1, payload=payload)
        reader = self.reader()
        try:
            result = reader.read("s-live", limit=12)
        finally:
            reader.close()
        self.assertTrue(result["coverage"]["truncated"])
        actual_max = max(row["end"] for row in result["segments"])
        self.assertEqual(result["freshness"]["max_transcribed_end"], actual_max)
        self.assertEqual(result["coverage"]["returned_rows"], len(result["segments"]))

    def test_symlink_database_and_invalid_inputs_are_rejected(self):
        link = Path(self.temp.name) / "linked.sqlite"
        link.symlink_to(self.db)
        with self.assertRaisesRegex(mc.ContextError, "database_path_rejected"):
            mc.Reader(link)
        parent_link = Path(self.temp.name) / "parent-link"
        parent_link.symlink_to(self.temp.name, target_is_directory=True)
        reader = mc.Reader(parent_link / self.db.name)
        reader.close()
        self.meeting("s-live")
        reader = self.reader()
        try:
            with self.assertRaisesRegex(mc.ContextError, "invalid_session"):
                reader.read("../other")
            with self.assertRaisesRegex(mc.ContextError, "query_required"):
                reader.search("s-live", "   ")
        finally:
            reader.close()

    def test_symlinked_sqlite_sidecars_are_rejected(self):
        other = Path(self.temp.name) / "sidecar.sqlite"
        conn = sqlite3.connect(other)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE marker(value TEXT)")
        conn.commit()
        conn.close()
        target = Path(self.temp.name) / "sidecar-target"
        target.write_text("x")
        Path(str(other) + "-shm").symlink_to(target)
        with self.assertRaisesRegex(mc.ContextError, "database_sidecar_path_rejected"):
            mc.Reader(other)

    def test_continuation_rejects_parent_revision_changed_after_first_page(self):
        self.meeting("s-live")
        text = "原文" * 50_000
        source = turn(text, start=0)
        source["parts"] = []
        self.segment("s-live", "p0", start=0, payload=[source], revision=1)
        reader = self.reader()
        try:
            first = reader.read("s-live", limit=1)
        finally:
            reader.close()
        cursor = first["continuations"][0]
        self.writer.execute("UPDATE segments SET revision=2,payload=? WHERE session='s-live' AND parent='p0'",
                            (json.dumps([turn("修订后的原文", start=0)], ensure_ascii=False),))
        self.writer.commit()
        reader = self.reader()
        try:
            with self.assertRaisesRegex(mc.ContextError, "continuation_source_changed"):
                reader.read("s-live", cursor=cursor)
        finally:
            reader.close()

    def test_cli_has_hard_wall_deadline_beyond_sqlite_progress_handler(self):
        self.meeting("s-live")
        self.state("s-live")
        out = io.StringIO()
        with mock.patch.object(mc, "DEADLINE_SECONDS", 0.05), \
             mock.patch.object(mc.Reader, "current", side_effect=lambda *_: time.sleep(0.2)), \
             contextlib.redirect_stdout(out):
            code = mc.main(["--database", str(self.db), "current"])
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(out.getvalue())["error"], "read_deadline_exceeded")

    def test_output_contains_actual_coverage_and_partial_state_without_claiming_continuity(self):
        self.meeting("s-live")
        self.segment("s-live", "p1", start=1, end=2,
                     payload=[turn("一段已确认内容", start=1), turn("识别中的字", final=False, start=1.5)])
        self.segment("s-live", "p2", start=20, end=21)
        reader = self.reader()
        try:
            result = reader.read("s-live", limit=1)
        finally:
            reader.close()
        self.assertEqual(result["coverage"]["returned_rows"], 1)
        self.assertEqual(result["coverage"]["total_rows"], 2)
        self.assertEqual(result["freshness"]["partial_count"], 1)
        self.assertEqual(result["freshness"]["max_transcribed_end"], 2)
        self.assertTrue(result["coverage"]["truncated"])
        self.assertEqual(result["next_offset"], 1)


if __name__ == "__main__":
    unittest.main()
