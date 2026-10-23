import json
import plistlib
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from scripts import merge_meetings


FIRST = "D2909AA6-B97C-4AA7-83AD-506F47CABA67"
SECOND = "2931F606-7911-46ED-8200-40038FA5896F"


class MergeMeetingsTests(unittest.TestCase):
    def make_source(self, root: Path, cache_id: str, title: str, session: str,
                    anchor: float, text: str, epoch: str, raw: bytes) -> Path:
        directory = root / cache_id
        directory.mkdir(parents=True)
        meeting = {"cache_id": cache_id, "session": session, "capture_origin_uptime": anchor - 100,
                   "absolute_clock": {"anchors": [{"relative_start": 0, "unix_time": anchor}]}}
        display = {"cache_id": cache_id, "title": title, "state": "ready"}
        (directory / "meeting.json").write_text(json.dumps(meeting), encoding="utf-8")
        (directory / "display-info.json").write_text(json.dumps(display), encoding="utf-8")
        (directory / "mic-transcript.jsonl").write_text(json.dumps({
            "event_id": f"{session}:event", "session": session, "source_id": "mic",
            "source_seq": 1, "segment_id": f"{session}:segment", "revision": 1,
            "type": "segment", "start": 1.0, "end": 2.0, "end_time_known": True,
            "final": True, "text": text,
            "speaker": {"session": session, "source": "mic", "epoch": epoch, "identity": "slot:0"},
            "speaker_runs": [{"start": 1.25, "end": 1.75, "text": text,
                              "speaker": {"session": session, "source": "mic", "epoch": epoch, "identity": "slot:0"}}],
            "word_spans": [{"start": 1.0, "end": 1.5}],
        }) + "\n" + json.dumps({"type": "asr_replay", "track": "mic",
                                 "source_id": "mic", "discard_segment_ids": [f"{session}:partial"],
                                 "resume_sample": 16000}) + "\n", encoding="utf-8")
        speaker_key = {"session": session, "source": "mic", "epoch": epoch, "identity": "slot:0"}
        segment_id = f"{session}:segment"
        names = {"schema": 2, "session": session, "order": [speaker_key],
                 "speakers": [{"key": speaker_key, "name": f"人工-{text}"}],
                 "assignments": [{"id": f"{segment_id}:word:1250", "key": speaker_key}],
                 "runAnchors": [{"id": f"{segment_id}:word:1250", "parent": segment_id,
                                 "session": session, "source": "mic", "epoch": epoch,
                                 "start": 1.25, "end": 1.75,
                                 "textSHA256": merge_meetings.hashlib.sha256(text.encode()).hexdigest()}],
                 "autoNames": [], "autoSuppressed": [], "semanticNames": [],
                 "personReferences": {}, "voiceConfirmations": [], "undo": [],
                 "aliases": [], "sentences": {}}
        (directory / "session-names.json").write_text(json.dumps(names), encoding="utf-8")
        self.write_track(directory, "mic", raw, anchor - 100)
        self.write_track(directory, "mic-raw", raw, anchor - 100)
        return directory

    @staticmethod
    def write_track(directory: Path, track: str, raw: bytes, origin: float) -> None:
        (directory / f"{track}-000000.pcm").write_bytes(raw)
        manifest = {"schema": 1, "track": track, "format": "pcm_s16le", "sample_rate": 16000,
                    "channels": 1, "written_bytes": len(raw), "origin_uptime": origin,
                    "asr_committed_bytes": len(raw), "offered_bytes": len(raw), "ended": True,
                    "chunks": [{"index": 0, "start_sample": 0, "bytes": len(raw),
                                "sha256": merge_meetings.hashlib.sha256(raw).hexdigest()}]}
        (directory / f"{track}-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return directory

    def test_staging_preserves_sources_offsets_timeline_and_speaker_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "cache"
            root.mkdir()
            first_session, second_session = str(uuid.uuid4()), str(uuid.uuid4())
            first_epoch, second_epoch = str(uuid.uuid4()), str(uuid.uuid4())
            first_pcm = b"\x01\x00" * 32000
            second_pcm = b"\x02\x00" * 32000
            first = self.make_source(root, FIRST, merge_meetings.EXPECTED[FIRST], first_session,
                                     1000.0, "alpha", first_epoch, first_pcm)
            second = self.make_source(root, SECOND, merge_meetings.EXPECTED[SECOND], second_session,
                                      1002.5, "beta", second_epoch, second_pcm)
            second_run_id = f"{second_session}:segment:word:1250"
            (second / "automatic-coarse-refinement.json").write_text(json.dumps({
                "schema": 1, "method": "audio_coarse_v1", "model": "synthetic-preserved",
                "records": [{"unit_id": second_run_id,
                             "original_text_sha256": merge_meetings.hashlib.sha256(b"beta").hexdigest(),
                             "text": "beta optimized",
                             "speaker_key": {"session": second_session, "source": "mic",
                                             "epoch": second_epoch, "identity": "slot:0"}}],
            }), encoding="utf-8")
            before = {FIRST: merge_meetings._walk_files(first), SECOND: merge_meetings._walk_files(second)}
            stage = Path(tmp) / "stage"
            with patch.object(merge_meetings, "DEFAULT_STAGE_ROOT", stage):
                result = merge_meetings.prepare_merge(root, stage, FIRST, SECOND)

            rows = [json.loads(line) for line in (result / "merged-mic-transcript.jsonl").read_text().splitlines()]
            self.assertEqual([row.get("text") for row in rows if row.get("type") == "segment"], ["alpha", "beta"])
            self.assertEqual(rows[0]["start"], 1.0)
            self.assertEqual(rows[2]["start"], 3.0)
            self.assertEqual(rows[2]["speaker_runs"][0]["start"], 3.25)
            self.assertEqual(rows[2]["word_spans"][0]["end"], 3.5)
            self.assertEqual(rows[0]["session"], rows[2]["session"])
            self.assertNotEqual(rows[0]["speaker"]["epoch"], rows[2]["speaker"]["epoch"])
            self.assertTrue(all("merge_source_cache_id" in row for row in rows))
            self.assertEqual([row["type"] for row in rows], ["segment", "asr_replay", "segment", "asr_replay"])
            self.assertEqual(rows[3]["resume_sample"], 16000)
            self.assertEqual(rows[3]["session"], rows[0]["session"])
            self.assertEqual(before[FIRST], merge_meetings._walk_files(first))
            self.assertEqual(before[SECOND], merge_meetings._walk_files(second))
            self.assertEqual(first_pcm, (result / "sources" / FIRST / "mic-raw-000000.pcm").read_bytes())
            self.assertEqual(second_pcm, (result / "sources" / SECOND / "mic-raw-000000.pcm").read_bytes())
            app_cache = result / "merged_recording" / merge_meetings._merged_ids(FIRST, SECOND)[0]
            app_rows = [json.loads(line) for line in (app_cache / "mic-transcript.jsonl").read_text().splitlines()]
            self.assertEqual(app_rows[3]["resume_sample"], 48000)
            merged_audio = (app_cache / "mic-000000.pcm").read_bytes()
            self.assertEqual(first_pcm + second_pcm, merged_audio)
            self.assertFalse((app_cache / "mic-raw-manifest.json").exists())
            self.assertFalse((app_cache / "reference-manifest.json").exists())
            self.assertEqual(second_pcm, (result / "sources" / SECOND / "mic-raw-000000.pcm").read_bytes())
            optimized = json.loads((app_cache / "automatic-coarse-refinement.json").read_text())
            self.assertIn("beta optimized", [item.get("text") for item in optimized["records"]])
            self.assertEqual(optimized["merge_projection"]["preserved_source_cache_id"], SECOND)
            clock = json.loads((app_cache / "meeting.json").read_text())["absolute_clock"]["anchors"]
            self.assertEqual(clock[1]["relative_start"], 2.0)
            self.assertEqual(clock[1]["unix_time"], 1002.5)
            names = json.loads((result / "merged-session-names.json").read_text())
            self.assertEqual(names["session"], rows[0]["session"])
            self.assertNotEqual(names["order"][0]["epoch"], names["order"][1]["epoch"])
            self.assertEqual(names["assignments"][1]["id"], f"{second_session}:segment:word:3250")
            self.assertEqual(names["runAnchors"][1]["id"], f"{second_session}:segment:word:3250")
            self.assertEqual(names["runAnchors"][1]["start"], 3.25)
            self.assertEqual(names["runAnchors"][1]["session"], rows[0]["session"])
            self.assertEqual(names["runAnchors"][1]["epoch"], rows[2]["speaker"]["epoch"])
            manifest = json.loads((result / "merge-manifest.json").read_text())
            self.assertTrue(manifest["event_ids_unique"])
            self.assertEqual(manifest["sources"][1]["offset_seconds"], 2.0)
            self.assertEqual(manifest["sources"][1]["wall_gap_seconds"], 0.5)

    def test_rejects_wrong_meeting_title_before_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "cache"
            root.mkdir()
            self.make_source(root, FIRST, "unexpected", str(uuid.uuid4()), 1, "a", "e1", b"a")
            self.make_source(root, SECOND, merge_meetings.EXPECTED[SECOND], str(uuid.uuid4()), 2, "b", "e2", b"b")
            stage = Path(tmp) / "stage"
            with patch.object(merge_meetings, "DEFAULT_STAGE_ROOT", stage):
                with self.assertRaisesRegex(ValueError, "Unexpected meeting title"):
                    merge_meetings.prepare_merge(root, stage, FIRST, SECOND)
            self.assertFalse(stage.exists())

    def test_rejects_symlink_in_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "cache"
            root.mkdir()
            a = self.make_source(root, FIRST, merge_meetings.EXPECTED[FIRST], str(uuid.uuid4()), 1, "a", "e1", b"\x00\x00")
            self.make_source(root, SECOND, merge_meetings.EXPECTED[SECOND], str(uuid.uuid4()), 2, "b", "e2", b"\x00\x00")
            (a / "unsafe-link").symlink_to(a / "mic-raw-000000.pcm")
            stage = Path(tmp) / "stage"
            with patch.object(merge_meetings, "DEFAULT_STAGE_ROOT", stage):
                with self.assertRaisesRegex(ValueError, "Refusing symlink"):
                    merge_meetings.prepare_merge(root, stage, FIRST, SECOND)

    def test_import_is_dry_run_by_default_and_recoverable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "cache"
            root.mkdir()
            first_session, second_session = str(uuid.uuid4()), str(uuid.uuid4())
            first = self.make_source(root, FIRST, merge_meetings.EXPECTED[FIRST], first_session,
                                     1000.0, "alpha", "epoch-a", b"\x01\x00" * 32000)
            second = self.make_source(root, SECOND, merge_meetings.EXPECTED[SECOND], second_session,
                                      1002.5, "beta", "epoch-b", b"\x02\x00" * 32000)
            second_run_id = f"{second_session}:segment:word:1250"
            (second / "automatic-coarse-refinement.json").write_text(json.dumps({
                "schema": 1, "method": "audio_coarse_v1", "model": "synthetic-preserved",
                "records": [{"unit_id": second_run_id,
                             "original_text_sha256": merge_meetings.hashlib.sha256(b"beta").hexdigest(),
                             "text": "beta optimized",
                             "speaker_key": {"session": second_session, "source": "mic",
                                             "epoch": "epoch-b", "identity": "slot:0"}}],
            }), encoding="utf-8")
            before = {FIRST: merge_meetings._walk_files(first), SECOND: merge_meetings._walk_files(second)}
            stage_root = Path(tmp) / "stage"
            app = Path(tmp) / "Test.app" / "Contents"
            app.mkdir(parents=True)
            lock = Path(tmp) / "desktop-ui.lock"
            lock.touch()
            info = app / "Info.plist"
            info.write_bytes(plistlib.dumps({"AppLockPath": str(lock)}))
            with patch.object(merge_meetings, "DEFAULT_STAGE_ROOT", stage_root):
                package = merge_meetings.prepare_merge(root, stage_root, FIRST, SECOND)
                dry = merge_meetings.import_staged(root, package, info)
                self.assertEqual(dry["mode"], "dry-run")
                self.assertFalse(dry["writes_performed"])
                self.assertEqual(before[FIRST], merge_meetings._walk_files(first))
                self.assertEqual(before[SECOND], merge_meetings._walk_files(second))

                imported = merge_meetings.import_staged(root, package, info, apply=True)
                merged_id = merge_meetings._merged_ids(FIRST, SECOND)[0]
                self.assertEqual(imported["mode"], "imported")
                self.assertTrue(imported["merged_hashes_verified"])
                self.assertFalse((root / FIRST).exists())
                self.assertFalse((root / SECOND).exists())
                self.assertTrue((root / merged_id).is_dir())
                originals = root / ".merged-originals" / merged_id
                self.assertEqual(before[FIRST], merge_meetings._walk_files(originals / FIRST))
                self.assertEqual(before[SECOND], merge_meetings._walk_files(originals / SECOND))
                self.assertTrue((originals / "import-receipt.json").is_file())

                rolled_back = merge_meetings.rollback_import(root, merged_id, info)
                self.assertEqual(rolled_back["mode"], "rolled-back")
                self.assertFalse((root / merged_id).exists())
                self.assertEqual(before[FIRST], merge_meetings._walk_files(root / FIRST))
                self.assertEqual(before[SECOND], merge_meetings._walk_files(root / SECOND))
                self.assertFalse(originals.exists())


if __name__ == "__main__":
    unittest.main()
