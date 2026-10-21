"""Phase 2 uses isolated projection/cache fixtures only; never the installed app."""
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

import meeting_context as mc
from tests import test_meeting_context as fixtures

ROOT = Path(__file__).resolve().parents[1]
CACHE_ID = "aabbccdd-1111-2222-3333-123456789abc"
SHA = "a" * 64
NOTES_SQL = """CREATE TABLE notes(session TEXT NOT NULL,id TEXT NOT NULL,rev INTEGER NOT NULL,
anchor_relative REAL,state TEXT NOT NULL,text TEXT NOT NULL,starred INTEGER NOT NULL,
archive INTEGER NOT NULL,images TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0,
PRIMARY KEY(session,id))"""


class MeetingContextNotesTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.MeetingContextTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.writer = self.fixture.writer
        # Match the actual AgentContext / SessionCache sibling layout.
        self.db = self.fixture.db
        # Avoid shared /tmp roots: relocate the open fixture database with backup.
        folder = Path(self.fixture.temp.name) / "AgentContext"
        folder.mkdir()
        self.db = folder / "context.sqlite"
        target = sqlite3.connect(self.db)
        self.writer.backup(target)
        self.writer.close()
        self.fixture.writer = self.writer = target
        self.cache = self.db.resolve().parent.parent / "SessionCache" / CACHE_ID
        self.fixture.meeting("s-live", phase="paused", revision=7)
        self.fixture.segment("s-live", "one", start=1, payload=[fixtures.turn("已确认原文", start=1)])
        metadata = json.loads(self.writer.execute("SELECT metadata FROM meetings").fetchone()[0])
        metadata.update(cache_id=CACHE_ID, transcription_complete=True, absolute_clock={
            "schema": 1, "basis": "capture_clock", "time_zone": "Asia/Shanghai",
            "anchors": [{"relative_start": 0, "unix_time": 1791215990},
                        {"relative_start": 20, "unix_time": 1791216610}]})
        self.writer.execute("UPDATE meetings SET metadata=?", (json.dumps(metadata),))
        self.writer.commit()

    def upgrade(self):
        self.writer.execute(NOTES_SQL)
        self.writer.execute("PRAGMA user_version=2")
        self.writer.commit()

    def note(self, id="note-1", *, relative=15.0, state="recording", text="专名：在场；预算15万",
             starred=True, archive=True, images=None, deleted=False, session="s-live", rev=1):
        self.writer.execute("INSERT OR REPLACE INTO notes VALUES(?,?,?,?,?,?,?,?,?,?)", (
            session, id, rev, relative, state, text, int(starred), int(archive),
            json.dumps(images or [], ensure_ascii=False), int(deleted)))
        self.writer.commit()

    def image(self):
        file = self.cache / f"notes/assets/{SHA}.png"
        file.parent.mkdir(parents=True, exist_ok=True)
        # Reader validates path references without reading image bytes.
        file.write_bytes(b"path-validation-only")
        return {"sha256": SHA, "cache_path": f"notes/assets/{SHA}.png", "ocr_text": "本机OCR"}

    def snapshot(self):
        reader = mc.Reader(self.db)
        try:
            return reader.archive_snapshot("s-live")
        finally:
            reader.close()

    def test_snapshot_structure_clock_and_reference_only(self):
        self.upgrade()
        image = self.image()
        self.note(images=[dict(image, private_bytes="must not escape")], archive=False)
        self.note("paused", relative=25, state="paused", starred=False)
        self.note("after", relative=None, state="after", starred=False)
        notes = {n["id"]: n for n in self.snapshot()["notes"]}
        self.assertEqual(notes["note-1"], {
            "id": "note-1", "rev": 1, "anchor_relative": 15.0, "anchor_clock_text": "00:00:05",
            "state": "recording", "text": "专名：在场；预算15万", "starred": True,
            "archive": False, "images": [image]})
        self.assertEqual(notes["paused"]["anchor_clock_text"], "00:10:15")
        self.assertIsNone(notes["after"]["anchor_clock_text"])
        self.assertIsNone(notes["after"]["anchor_relative"])

    def test_deleted_notes_and_other_sessions_are_not_returned(self):
        self.upgrade()
        self.note(deleted=True, images=[{"malformed": "deleted image ignored"}])
        self.note("other", session="another-meeting")
        self.assertNotIn("notes", self.snapshot())
        self.note(deleted=False, rev=3)
        self.assertEqual(self.snapshot()["notes"][0]["rev"], 3)

    def test_snapshot_returns_metadata_cache_id_only_when_notes_are_present(self):
        self.upgrade()
        before = json.dumps(self.snapshot(), ensure_ascii=False, separators=(",", ":")).encode()
        self.assertNotIn(b'"cache_id"', before)
        for images in ([], [self.image()]):
            with self.subTest(has_image=bool(images)):
                self.note(images=images)
                metadata = json.loads(self.writer.execute("SELECT metadata FROM meetings").fetchone()[0])
                self.assertEqual(self.snapshot()["cache_id"], metadata["cache_id"])
        self.note(deleted=True)
        self.assertEqual(before, json.dumps(self.snapshot(), ensure_ascii=False, separators=(",", ":")).encode())

    def test_text_notes_reject_missing_or_invalid_cache_id(self):
        self.upgrade()
        self.note()
        metadata = json.loads(self.writer.execute("SELECT metadata FROM meetings").fetchone()[0])
        for value in (None, "../other-cache", "not-a-uuid"):
            with self.subTest(cache_id=value):
                metadata["cache_id"] = value
                self.writer.execute("UPDATE meetings SET metadata=?", (json.dumps(metadata),))
                self.writer.commit()
                with self.assertRaisesRegex(mc.ContextError, "invalid_note_cache_id"):
                    self.snapshot()

    def test_new_york_meeting_notes_use_shanghai_time_and_same_capture_anchors(self):
        self.upgrade()
        metadata = json.loads(self.writer.execute("SELECT metadata FROM meetings").fetchone()[0])
        metadata["absolute_clock"]["time_zone"] = "America/New_York"
        self.writer.execute("UPDATE meetings SET metadata=?", (json.dumps(metadata),))
        self.writer.commit()
        self.note("recording", relative=15)
        self.note("resume-boundary", relative=20)
        self.note("paused", relative=25, state="paused")
        self.note("after", relative=None, state="after")
        clocks = {note["id"]: note["anchor_clock_text"] for note in self.snapshot()["notes"]}
        self.assertEqual(clocks, {"recording": "00:00:05", "resume-boundary": "00:10:10",
                                  "paused": "00:10:15", "after": None})

    def test_empty_schema1_schema2_and_deleted_only_are_byte_identical(self):
        before = json.dumps(self.snapshot(), ensure_ascii=False, separators=(",", ":")).encode()
        self.upgrade()
        self.assertEqual(before, json.dumps(self.snapshot(), ensure_ascii=False, separators=(",", ":")).encode())
        self.note(deleted=True)
        self.assertEqual(before, json.dumps(self.snapshot(), ensure_ascii=False, separators=(",", ":")).encode())
        self.assertNotIn(b'"notes"', before)
        self.assertNotIn(b'"cache_id"', before)

    def test_four_conversation_tools_never_expose_notes(self):
        self.upgrade()
        self.note(text="ONLY_NOTE_SECRET")
        self.fixture.state(phase="paused")
        reader = mc.Reader(self.db)
        try:
            for value in (reader.current(), reader.read("s-live"), reader.search("s-live", "ONLY_NOTE_SECRET"),
                          reader.changes("s-live", 0)):
                value.pop("query", None)  # Search echoes the supplied query, not a note hit.
                encoded = json.dumps(value)
                self.assertNotIn('"notes"', encoded)
                self.assertNotIn("ONLY_NOTE_SECRET", encoded)
                self.assertLessEqual(len(encoded), mc.MAX_OUTPUT_CHARS)
        finally:
            reader.close()

    def test_image_traversal_absolute_and_wrong_sha_paths_rejected(self):
        self.upgrade()
        image = self.image()
        for path in ("../other.png", "/tmp/image.png", f"notes/assets/../../{SHA}.png",
                     f"notes/assets/{'b' * 64}.png", f"notes/assets/{SHA}.png/extra"):
            with self.subTest(path=path):
                self.note(images=[dict(image, cache_path=path)])
                with self.assertRaisesRegex(mc.ContextError, "note_image_path_rejected"):
                    self.snapshot()

    def test_image_leaf_and_parent_symlinks_even_within_cache_rejected(self):
        self.upgrade()
        image = self.image()
        path = self.cache / image["cache_path"]
        actual = path.with_suffix(".original")
        path.rename(actual)
        path.symlink_to(actual)
        self.note(images=[image])
        with self.assertRaisesRegex(mc.ContextError, "note_image_path_rejected"):
            self.snapshot()
        path.unlink()
        actual.rename(path)
        assets = path.parent
        moved = assets.with_name("real-assets")
        assets.rename(moved)
        assets.symlink_to(moved, target_is_directory=True)
        with self.assertRaisesRegex(mc.ContextError, "note_image_path_rejected"):
            self.snapshot()

    def test_cache_directory_symlink_and_missing_image_rejected(self):
        self.upgrade()
        image = self.image()
        self.note(images=[image])
        (self.cache / image["cache_path"]).unlink()
        with self.assertRaisesRegex(mc.ContextError, "note_image_path_rejected"):
            self.snapshot()
        self.image()
        moved = self.cache.with_name("other-cache")
        self.cache.rename(moved)
        self.cache.symlink_to(moved, target_is_directory=True)
        with self.assertRaisesRegex(mc.ContextError, "note_image_path_rejected"):
            self.snapshot()

    def test_invalid_cache_id_and_note_clock_rejected(self):
        self.upgrade()
        self.note(images=[self.image()])
        metadata = json.loads(self.writer.execute("SELECT metadata FROM meetings").fetchone()[0])
        metadata["cache_id"] = "../other-cache"
        self.writer.execute("UPDATE meetings SET metadata=?", (json.dumps(metadata),))
        self.writer.commit()
        with self.assertRaisesRegex(mc.ContextError, "note_image_path_rejected"):
            self.snapshot()
        self.note()
        metadata.pop("absolute_clock")
        self.writer.execute("UPDATE meetings SET metadata=?", (json.dumps(metadata),))
        self.writer.commit()
        with self.assertRaisesRegex(mc.ContextError, "note_clock_unavailable"):
            self.snapshot()

    def test_notes_share_wal_snapshot_and_deadline(self):
        self.upgrade()
        self.note(text="修改前")
        reader = mc.Reader(self.db)
        try:
            before = reader.archive_snapshot("s-live")
            self.note(text="修改后", rev=2)
            self.assertEqual(reader.archive_snapshot("s-live"), before)
            reader.deadline = time.monotonic() - 1
            with self.assertRaisesRegex(mc.ContextError, "read_deadline_exceeded"):
                reader.archive_snapshot("s-live")
        finally:
            reader.close()
        self.assertEqual(self.snapshot()["notes"][0]["text"], "修改后")

    def test_archive_retains_full_note_text_and_ocr(self):
        self.upgrade()
        image = self.image()
        image["ocr_text"] = "识别" * mc.MAX_OUTPUT_CHARS
        self.note(text="笔记" * mc.MAX_OUTPUT_CHARS, images=[image])
        result = self.snapshot()["notes"][0]
        self.assertEqual(len(result["text"]), 2 * mc.MAX_OUTPUT_CHARS)
        self.assertEqual(result["images"][0]["ocr_text"], image["ocr_text"])

    def test_future_schema_explicitly_rejected(self):
        self.writer.execute("PRAGMA user_version=3")
        with self.assertRaisesRegex(mc.ContextError, "unsupported_database_schema"):
            mc.Reader(self.db)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "native migration needs macOS Swift")
class MeetingContextMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        folder = Path(cls.temp.name)
        # Compile the actual store, publisher and notes source without Delegate
        # or NSApplication startup. The unused export dependency is a stub.
        source = (ROOT / "native/MeetingAgentContext.swift").read_text().split("extension Delegate", 1)[0]
        source += (ROOT / "native/MeetingNotes.swift").read_text()
        source += (ROOT / "native/MeetingAbsoluteTime.swift").read_text().split("func meetingAbsoluteTimeChecks", 1)[0]
        source += '''
struct Failure: Error { let code: String }
struct CachedMeeting {
    let directory: URL
    func metadata() throws -> [String:Any] { [:] }
}
func publishNotes(_ directory: URL) throws {
    let cacheID = "aabbccdd-1111-2222-3333-123456789abc"
    let cache = directory.appendingPathComponent("SessionCache/" + cacheID)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let source = MeetingNotesStore(directory: cache)
    let publisher = MeetingContextPublisher(directory: directory.appendingPathComponent("AgentContext"))
    publisher.update(["schema":1,"session":"s-live","cache_id":cacheID,"phase":"paused",
                      "local_only":false,"projection_updating":false,"transcription_complete":true,
                      "absolute_clock":["schema":1,"basis":"capture_clock","time_zone":"Asia/Shanghai",
                                        "anchors":[["relative_start":0.0,"unix_time":1791215990.0]]]])
    publisher.trackNotes(session:"s-live",directory:cache)
    publisher.flushForChecks()
    guard !FileManager.default.fileExists(atPath: source.notes.path) else { throw Failure(code:"empty_source_created") }
    let note = try MeetingNotesStore.queue.sync { try source.create(text:"初稿",anchor:MeetingNoteAnchor(relative:15,state:"paused")) }
    publisher.flushForChecks()
    try MeetingNotesStore.queue.sync {
        _ = try source.change(note.note_id,text:"仅参考的修订",starred:true,archive:false)
        let deleted = try source.create(text:"不得出现在快照",anchor:nil)
        _ = try source.change(deleted.note_id,op:"delete")
    }
    // Derived OCR remains in flight while text/image rows can be published.
    let gate = DispatchSemaphore(value:0)
    source.recognize = { _ in gate.wait();return "头脑风暴 OCR" }
    defer { gate.signal() }
    let pixels = Data(repeating:180,count:16)
    let provider = CGDataProvider(data:pixels as CFData)!
    let cg = CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,
                     space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),
                     provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,cg,nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure(code:"image_fixture") }
    _ = try MeetingNotesStore.queue.sync { try source.create(images:[output as Data],anchor:nil) }
    publisher.flushForChecks()
    guard publisher.lastError == nil else { throw Failure(code:"note_publication_before_ocr") }
    publisher.clearCurrent() // Delayed OCR still belongs to this cache after switching away.
    gate.signal()
    guard source.ocrTasks.wait(timeout:.now()+5) == .success else { throw Failure(code:"ocr_fixture_timeout") }
    // Exercise the production two-second heartbeat, without manually flushing.
    Thread.sleep(forTimeInterval:2.2)
    var observation:OpaquePointer?,statement:OpaquePointer?
    sqlite3_open_v2(directory.appendingPathComponent("AgentContext/context.sqlite").path,&observation,SQLITE_OPEN_READONLY,nil)
    sqlite3_prepare_v2(observation,"SELECT COUNT(*) FROM notes WHERE images LIKE '%头脑风暴 OCR%'",-1,&statement,nil)
    let ocrPublished = sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement,0) == 1
    sqlite3_finalize(statement);sqlite3_close(observation)
    guard ocrPublished else { throw Failure(code:"ocr_heartbeat_refresh_missing") }
    // Force a locked transaction, then a newer durable edit before retry.
    var blocker:OpaquePointer?
    sqlite3_open(directory.appendingPathComponent("AgentContext/context.sqlite").path,&blocker)
    sqlite3_exec(blocker,"BEGIN IMMEDIATE",nil,nil,nil)
    try MeetingNotesStore.queue.sync { _ = try source.change(note.note_id,text:"锁住旧稿") }
    publisher.flushForChecks()
    guard publisher.lastError != nil else { throw Failure(code:"lock_failure_not_detected") }
    try MeetingNotesStore.queue.sync { _ = try source.change(note.note_id,text:"仅参考的最终稿") }
    sqlite3_exec(blocker,"ROLLBACK",nil,nil,nil);sqlite3_close(blocker)
    publisher.flushForChecks()
    guard publisher.lastError == nil else { throw Failure(code:"note_retry_failed") }
    // The full source exceeds one mailbox batch. Flush must not return early.
    try MeetingNotesStore.queue.sync {
        for _ in 0..<130 { _ = try source.create(starred:true,anchor:MeetingNoteAnchor(relative:20,state:"recording")) }
    }
    let done=DispatchSemaphore(value:0)
    var success=false
    publisher.flush { success=$0;done.signal() }
    guard done.wait(timeout:.now()+10) == .success,success else { throw Failure(code:"notes_batch_flush_failed") }
}
'''
        source += '''
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    if CommandLine.arguments.contains("--publish") { try publishNotes(directory) }
    else { for _ in 0..<3 { let store = try MeetingContextStore(directory: directory); _ = try store.revision("s-live") } }
} catch { print(String(describing: error)); exit(1) }
'''
        swift = folder / "main.swift"
        swift.write_text(source)
        cls.binary = folder / "migrate"
        result = subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(ROOT / ".runtime/build/module-cache"),
                                 str(swift), "-o", str(cls.binary)], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def test_production_notes_to_publisher_to_reader_without_appkit_startup(self):
        # Foundation standardizes /private/var aliases differently from pathlib;
        # use the project's isolated QA root, as native note checks do.
        evidence = ROOT / ".runtime/meeting-notes-1018"
        evidence.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=evidence) as folder:
            result = subprocess.run([str(self.binary), str(Path(folder).resolve()), "--publish"], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            reader = mc.Reader(Path(folder) / "AgentContext/context.sqlite")
            try:
                snapshot = reader.archive_snapshot("s-live")
            finally:
                reader.close()
            self.assertEqual(len(snapshot["notes"]), 132)
            reference = next(n for n in snapshot["notes"] if not n["archive"])
            self.assertEqual(reference["text"], "仅参考的最终稿")
            self.assertEqual(reference["rev"], 4)
            self.assertEqual(reference["anchor_clock_text"], "00:00:05")
            self.assertEqual(reference["state"], "paused")
            self.assertTrue(reference["starred"])
            image_note = next(n for n in snapshot["notes"] if n["images"])
            self.assertEqual(image_note["images"][0]["ocr_text"], "头脑风暴 OCR")
            self.assertIsNone(image_note["anchor_clock_text"])
            self.assertNotIn("不得出现在快照", json.dumps(snapshot, ensure_ascii=False))
            self.assertFalse(snapshot["projection_updating"])

    def test_production_schema_migration_is_idempotent_and_preserves_rows(self):
        fixture = fixtures.MeetingContextTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        fixture.meeting("s-live", phase="paused", revision=9)
        fixture.segment("s-live", "p", start=1)
        before = {t: fixture.writer.execute(f"SELECT * FROM {t}").fetchall() for t in ("meetings", "segments", "state")}
        result = subprocess.run([str(self.binary), str(fixture.db.parent)], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(fixture.writer.execute("PRAGMA user_version").fetchone()[0], 2)
        for table, rows in before.items():
            self.assertEqual(fixture.writer.execute(f"SELECT * FROM {table}").fetchall(), rows)
        fixture.writer.execute("INSERT INTO notes VALUES('s-live','n',2,NULL,'after','保留',1,0,'[]',0)")
        fixture.writer.commit()
        result = subprocess.run([str(self.binary), str(fixture.db.parent)], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(fixture.writer.execute("SELECT text,rev,archive FROM notes").fetchone(), ("保留", 2, 0))

    def test_production_migration_rejects_future_schema_without_downgrading(self):
        with tempfile.TemporaryDirectory() as folder:
            db = sqlite3.connect(Path(folder) / "context.sqlite")
            try:
                db.execute("PRAGMA user_version=3")
                result = subprocess.run([str(self.binary), folder], capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unsupported_database_schema", result.stdout)
                self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 3)
            finally:
                db.close()
