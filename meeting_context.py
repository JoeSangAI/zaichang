#!/usr/bin/env python3
"""Bounded, read-only access to the active "在场" meeting projection.

This module deliberately has no model, network, process-launch, or capture
integration. It reads only the small SQLite projection published by the app.
"""

from __future__ import annotations

import argparse
import base64
import copy
import json
import math
import os
import re
import sqlite3
import signal
import sys
import time
import unicodedata
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from typing import Any, Iterable
from urllib.parse import quote
from runtime_config import data_root

SCHEMA_VERSION = 1
# The state/response protocol remains v1; only the database adds notes in v2.
DATABASE_SCHEMAS = {1, 2}
DEFAULT_DB = data_root() / "AgentContext/context.sqlite"
BUSY_TIMEOUT_MS = 250
DEADLINE_SECONDS = 3.0
CURRENT_MAX_AGE_SECONDS = 10.0
MAX_OUTPUT_CHARS = 16_000
MAX_LIMIT = 120
LIVE_PHASES = {"recording", "paused"}
ALL_PHASES = LIVE_PHASES | {"stopping", "idle", "stopped", "ended", "failed", "connecting"}


class ContextError(Exception):
    """Expected, user-safe reader error."""


def _json_object(value: str, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except (TypeError, json.JSONDecodeError) as exc:
        raise ContextError(f"invalid_{label}") from exc
    if not isinstance(parsed, dict):
        raise ContextError(f"invalid_{label}")
    return parsed


def _validate_db_path(path: Path) -> Path:
    # Don't follow a substituted database, including a symlinked leaf.
    try:
        if path.is_symlink():
            raise ContextError("database_path_rejected")
        resolved = path.resolve(strict=True)
        if not resolved.is_file():
            raise ContextError("database_unavailable")
        for suffix in ("-wal", "-shm"):
            if Path(str(resolved) + suffix).is_symlink():
                raise ContextError("database_sidecar_path_rejected")
    except FileNotFoundError as exc:
        raise ContextError("database_unavailable") from exc
    except OSError as exc:
        raise ContextError("database_unavailable") from exc
    return resolved


class Reader:
    def __init__(self, database: Path, *, now: float | None = None):
        self.started = time.monotonic()
        self.deadline = self.started + DEADLINE_SECONDS
        self.now = time.time() if now is None else now
        db = _validate_db_path(database)
        self.cache_root = db.parent.parent / "SessionCache"
        uri = "file:" + quote(str(db), safe="/") + "?mode=ro"
        try:
            self.conn = sqlite3.connect(uri, uri=True, timeout=BUSY_TIMEOUT_MS / 1000)
            self.conn.row_factory = sqlite3.Row
            self.conn.execute(f"PRAGMA busy_timeout={BUSY_TIMEOUT_MS}")
            self.conn.execute("PRAGMA query_only=ON")
            self.conn.set_progress_handler(self._progress, 1000)
            # Read the schema and all rows from the same WAL snapshot, even
            # when the writer migrates a v1 database concurrently.
            self.conn.execute("BEGIN")
            self.database_schema = self.conn.execute("PRAGMA user_version").fetchone()[0]
            if self.database_schema not in DATABASE_SCHEMAS:
                self.conn.close()
                raise ContextError("unsupported_database_schema")
        except sqlite3.Error as exc:
            raise ContextError("database_busy_or_unavailable") from exc

    def close(self) -> None:
        self.conn.close()

    def _progress(self) -> int:
        return 1 if time.monotonic() > self.deadline else 0

    def _check_deadline(self) -> None:
        if time.monotonic() > self.deadline:
            raise ContextError("read_deadline_exceeded")

    def _current(self) -> dict[str, Any] | None:
        row = self.conn.execute("SELECT value FROM state WHERE key='current'").fetchone()
        return _json_object(row[0], "current_state") if row else None

    def _meeting(self, session: str) -> tuple[dict[str, Any], int]:
        _validate_session(session)
        row = self.conn.execute(
            "SELECT metadata,revision FROM meetings WHERE session=?", (session,)
        ).fetchone()
        if not row:
            raise ContextError("meeting_not_found")
        metadata = _json_object(row[0], "meeting_metadata")
        if metadata.get("session") != session:
            raise ContextError("meeting_session_mismatch")
        if metadata.get("phase") not in ALL_PHASES:
            raise ContextError("invalid_meeting_phase")
        if not isinstance(metadata.get("local_only"), bool):
            raise ContextError("invalid_meeting_metadata")
        if not isinstance(metadata.get("projection_updating"), bool):
            raise ContextError("invalid_meeting_metadata")
        return metadata, int(row[1])

    def _mode(self, session: str, metadata: dict[str, Any]) -> str:
        current = self._current()
        if current and current.get("session") == session:
            writer_matches = current.get("writer_id") == metadata.get("writer_id")
            phase_matches = current.get("phase") == metadata.get("phase")
            if writer_matches and phase_matches and _state_is_live(current, self.now) and metadata["phase"] == "recording":
                return "live_meeting"
            if writer_matches and phase_matches and _state_is_live(current, self.now) and metadata["phase"] == "paused":
                return "paused"
        return "history"

    def current(self, query: str | None = None) -> dict[str, Any]:
        state = self._current()
        status: dict[str, Any] = {"status": "no_current_meeting"}
        if not state:
            return status
        session = state.get("session")
        status["current_status"] = state.get("phase")
        if isinstance(session, str):
            status["last_session"] = session
        if not _state_is_live(state, self.now):
            status["status"] = "no_current_meeting"
            status["reason"] = "writer_unreachable_or_stale"
            status["recording_state_verified"] = False
            return status
        if state.get("schema") != SCHEMA_VERSION or not isinstance(state.get("writer_id"), str):
            status["status"] = "no_current_meeting"
            return status
        if state.get("phase") not in LIVE_PHASES:
            status["status"] = "no_current_meeting"
            return status
        if not isinstance(session, str):
            status["status"] = "no_current_meeting"
            return status
        metadata, revision = self._meeting(session)
        if metadata.get("writer_id") != state.get("writer_id"):
            return {"status": "no_current_meeting", "current_status": state.get("phase"),
                    "last_session": session}
        if metadata.get("phase") not in LIVE_PHASES or metadata.get("phase") != state.get("phase"):
            return {"status": "no_current_meeting", "current_status": state.get("phase"),
                    "last_session": session}
        if metadata.get("local_only"):
            return self._recording_only(session, metadata, revision)
        mode = "live_meeting" if metadata["phase"] == "recording" else "paused"
        rows, total, offset = self._recent_rows(session, limit=MAX_LIMIT)
        query_rows: list[dict[str, Any]] = []
        priority: set[str] = set()
        if query and _query_terms(query):
            query_rows, _, priority = self._search_rows(session, query, limit=12, neighborhood=1)
        rows = _merge_rows(rows, query_rows)
        return self._response(session, metadata, revision, mode, rows, total, offset,
                              query=query, current=True, priority_parents=priority)

    def read(self, session: str, offset: int = 0, limit: int = 60,
             cursor: str | None = None) -> dict[str, Any]:
        _validate_page(offset, limit)
        metadata, revision = self._meeting(session)
        if metadata.get("local_only"):
            return self._recording_only(session, metadata, revision)
        if cursor:
            token = _decode_cursor(cursor)
            if token.get("session") != session or token.get("kind") not in {"text", "texts", "turns", "parts"}:
                raise ContextError("invalid_cursor")
            result = self._read_continuation(session, metadata, revision, token)
            if metadata.get("projection_updating"):
                result.update(status="updating", speaker_labels_verified=False,
                              projection_state="committed_text_pending_speaker_projection")
                item = result.get("continuation_chunk", {}).get("item")
                if isinstance(item, dict):
                    for value in [item, *item.get("parts", [])]:
                        _mask_stale_speaker(value)
            return result
        rows, total, actual_offset = self._page_rows(session, offset, min(limit, MAX_LIMIT))
        return self._response(session, metadata, revision, self._mode(session, metadata),
                              rows, total, actual_offset, next_offset=actual_offset + len(rows),
                              page_kind="read")

    def archive_snapshot(self, session: str) -> dict[str, Any]:
        """Complete settled text on one read-only WAL snapshot; never start capture.

        This internal adapter deliberately bypasses the conversational page size,
        keeping all turns and identity provenance for shared archive preparation.
        """
        metadata, revision = self._meeting(session)
        if (metadata.get("phase") not in {"paused", "stopped", "ended"}
                or metadata.get("local_only") or metadata.get("projection_updating")
                or metadata.get("transcription_complete") is not True):
            raise ContextError("meeting_not_ready_for_archive")
        total = self.conn.execute(
            "SELECT count(*) FROM segments WHERE session=? AND deleted=0", (session,)
        ).fetchone()[0]
        rows = self._select_rows(session, 0, total)
        # Transport completion and recognition confidence are independent. A
        # stopped, drained recording can retain provider partials forever (for
        # example an interrupted short utterance). Preserve every such turn and
        # its original final flag; do not deadlock the whole meeting, manufacture
        # a final result, or silently discard the uncertain words.
        turns = [turn for row in rows for turn in row["turns"]]
        nonfinal = [turn for turn in turns if turn.get("final") is not True]
        uncertainty = {
            "kind": "retained_nonfinal_transcript",
            "nonfinal_turn_count": len(nonfinal),
            "final_turn_count": len(turns) - len(nonfinal),
            "nonfinal_turn_ids": [turn.get("id") for turn in nonfinal],
            "policy": "preserve_as_uncertain_not_fact",
        }
        self._check_deadline()
        result = {"status": "ok", "session_id": session, "revision": revision,
                **_safe_metadata(metadata),
                "text": json.dumps(rows, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
                "source": "zaichang", "complete": True,
                "uncertainty": uncertainty}
        notes = self._archive_notes(session, metadata)
        # Absence is deliberate: existing archive confirmations and byte-level
        # snapshots of meetings without notes must stay valid on both schemas.
        if notes:
            cache_id = metadata.get("cache_id")
            if not isinstance(cache_id, str) or re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", cache_id) is None:
                raise ContextError("invalid_note_cache_id")
            result["notes"] = notes
            result["cache_id"] = cache_id
        self._check_deadline()
        return result

    def _archive_notes(self, session: str, metadata: dict[str, Any]) -> list[dict[str, Any]]:
        if self.database_schema == 1:
            return []
        notes = []
        for row in self.conn.execute(
                "SELECT id,rev,anchor_relative,state,text,starred,archive,images "
                "FROM notes WHERE session=? AND deleted=0 "
                "ORDER BY anchor_relative IS NULL,anchor_relative,id", (session,)):
            self._check_deadline()
            relative, state = row["anchor_relative"], row["state"]
            if (not isinstance(row["id"], str) or len(row["id"]) > 300
                    or type(row["rev"]) is not int or row["rev"] < 1
                    or not isinstance(row["text"], str)
                    or row["starred"] not in (0, 1) or row["archive"] not in (0, 1)
                    or state not in {"recording", "paused", "after"}
                    or (state == "after" and relative is not None)
                    or (state != "after" and (type(relative) not in (int, float)
                        or not math.isfinite(relative) or relative < 0))):
                raise ContextError("invalid_note_payload")
            try:
                images = json.loads(row["images"])
            except (TypeError, json.JSONDecodeError) as exc:
                raise ContextError("invalid_note_images") from exc
            if not isinstance(images, list):
                raise ContextError("invalid_note_images")
            safe_images = []
            for image in images:
                self._check_deadline()
                if not isinstance(image, dict) or not isinstance(image.get("ocr_text"), str):
                    raise ContextError("invalid_note_images")
                sha, path = image.get("sha256"), image.get("cache_path")
                if (not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{64}", sha) is None
                        or path not in (f"notes/assets/{sha}.png", f"notes/assets/{sha}.jpg")):
                    raise ContextError("note_image_path_rejected")
                self._validate_note_image(metadata.get("cache_id"), path)
                safe_images.append({"sha256": sha, "cache_path": path, "ocr_text": image["ocr_text"]})
            notes.append({"id": row["id"], "rev": row["rev"], "anchor_relative": relative,
                          "anchor_clock_text": None if state == "after" else _note_clock(metadata.get("absolute_clock"), relative),
                          "state": state, "text": row["text"], "starred": bool(row["starred"]),
                          "archive": bool(row["archive"]), "images": safe_images})
        return notes

    def _validate_note_image(self, cache_id: Any, relative: str) -> None:
        if not isinstance(cache_id, str) or re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", cache_id) is None:
            raise ContextError("note_image_path_rejected")
        cache = self.cache_root / cache_id
        image = cache / relative
        try:
            # Reject even an in-cache symlink, including symlinked ancestors.
            for part in (image, *image.parents):
                self._check_deadline()
                if part.is_symlink():
                    raise ContextError("note_image_path_rejected")
            image.resolve(strict=True).relative_to(cache.resolve(strict=True))
            if not image.is_file():
                raise ContextError("note_image_path_rejected")
        except (OSError, ValueError, RuntimeError) as exc:
            raise ContextError("note_image_path_rejected") from exc

    def search(self, session: str, query: str, limit: int = 20) -> dict[str, Any]:
        _validate_page(0, limit)
        if not query.strip():
            raise ContextError("query_required")
        metadata, revision = self._meeting(session)
        if metadata.get("local_only"):
            return self._recording_only(session, metadata, revision)
        rows, total, hits = self._search_rows(session, query, min(limit, 12), neighborhood=1)
        result = self._response(session, metadata, revision, self._mode(session, metadata),
                                rows, total, 0, query=query, priority_parents=hits)
        result["coverage"]["scope"] = "bounded_search_matches_and_neighbors"
        result["coverage"]["meeting_total_rows"] = self.conn.execute(
            "SELECT count(*) FROM segments WHERE session=? AND deleted=0", (session,)
        ).fetchone()[0]
        return result

    def changes(self, session: str, after_revision: int, limit: int = 60,
                cursor: str | None = None) -> dict[str, Any]:
        _validate_page(0, limit)
        if after_revision < 0:
            raise ContextError("invalid_revision")
        metadata, revision = self._meeting(session)
        if metadata.get("local_only"):
            return self._recording_only(session, metadata, revision)
        after_parent = ""
        if cursor:
            token = _decode_cursor(cursor)
            if token.get("kind") != "changes" or token.get("session") != session:
                raise ContextError("invalid_cursor")
            after_revision = token.get("revision")
            after_parent = token.get("parent")
            if not isinstance(after_revision, int) or after_revision < 0 or not isinstance(after_parent, str):
                raise ContextError("invalid_cursor")
            predicate = "(updated_revision>? OR (updated_revision=? AND parent>?))"
            bind = (session, after_revision, after_revision, after_parent)
        else:
            predicate = "updated_revision>?"
            bind = (session, after_revision)
        raw = self.conn.execute(
            "SELECT parent,revision,start,end,payload,updated_revision,deleted FROM segments "
            f"WHERE session=? AND {predicate} ORDER BY updated_revision,parent LIMIT ?",
            (*bind, min(limit, MAX_LIMIT)),
        ).fetchall()
        rows = [_segment_row(row) for row in raw]
        total = self.conn.execute(
            f"SELECT count(*) FROM segments WHERE session=? AND {predicate}", bind,
        ).fetchone()[0]
        result = self._response(session, metadata, revision, self._mode(session, metadata),
                                rows, total, 0, after_revision=after_revision,
                                next_revision=max((r["updated_revision"] for r in rows), default=after_revision),
                                page_kind="changes")
        delivered = result["segments"]
        if delivered and len(delivered) < total:
            last = delivered[-1]
            result["next_cursor"] = _encode_cursor({"kind": "changes", "session": session,
                                                     "revision": last["updated_revision"],
                                                     "parent": last["parent"]})
        else:
            result["next_cursor"] = None
        return result

    def _recent_rows(self, session: str, limit: int) -> tuple[list[dict[str, Any]], int, int]:
        total = self.conn.execute(
            "SELECT count(*) FROM segments WHERE session=? AND deleted=0", (session,)
        ).fetchone()[0]
        offset = max(0, total - limit)
        rows = self._select_recent_desc(session, limit)
        rows.sort(key=lambda r: (r["start"], r["parent"]))
        return rows, total, offset

    def _page_rows(self, session: str, offset: int, limit: int) -> tuple[list[dict[str, Any]], int, int]:
        total = self.conn.execute(
            "SELECT count(*) FROM segments WHERE session=? AND deleted=0", (session,)
        ).fetchone()[0]
        offset = min(offset, total)
        return self._select_rows(session, offset, limit), total, offset

    def _select_rows(self, session: str, offset: int, limit: int) -> list[dict[str, Any]]:
        self._check_deadline()
        raw = self.conn.execute(
            "SELECT parent,revision,start,end,payload,updated_revision,deleted FROM segments "
            "WHERE session=? AND deleted=0 ORDER BY start,parent LIMIT ? OFFSET ?",
            (session, limit, offset),
        ).fetchall()
        return [_segment_row(row) for row in raw]

    def _select_recent_desc(self, session: str, limit: int) -> list[dict[str, Any]]:
        self._check_deadline()
        raw = self.conn.execute(
            "SELECT parent,revision,start,end,payload,updated_revision,deleted FROM segments "
            "WHERE session=? AND deleted=0 ORDER BY start DESC,parent DESC LIMIT ?",
            (session, limit),
        ).fetchall()
        return [_segment_row(row) for row in raw]

    def _search_rows(self, session: str, query: str, limit: int, neighborhood: int) -> tuple[list[dict[str, Any]], int, set[str]]:
        terms = _query_terms(query)
        if not terms:
            raise ContextError("query_required")
        # Search all non-deleted rows, including older material. SQLite LIKE is
        # parameterized; a progress handler bounds pathological long meetings.
        clauses = " OR ".join("payload LIKE ? ESCAPE '\\'" for _ in terms)
        args: list[Any] = [session, *(_like_pattern(term) for term in terms)]
        raw = self.conn.execute(
            "SELECT parent,revision,start,end,payload,updated_revision,deleted FROM segments "
            f"WHERE session=? AND deleted=0 AND ({clauses}) ORDER BY start DESC,parent DESC LIMIT ?",
            [*args, limit],
        ).fetchall()
        hits = [_segment_row(row) for row in raw]
        hit_parents = {hit["parent"] for hit in hits}
        self._check_deadline()
        # Keep separate utterances even if text repeats; context is attached by
        # persisted order, not deduplicated by text.
        rows_by_parent = {row["parent"]: row for row in hits}
        if neighborhood and hits:
            # At most `limit` small indexed time-window reads; avoid one large
            # OR expression whose cost grows with a 500-hit meeting scan.
            for hit in hits:
                left = max(0.0, hit["start"] - 12.0)
                right = hit["end"] + 12.0 if hit["end"] is not None else hit["start"] + 12.0
                around = self.conn.execute(
                    "SELECT parent,revision,start,end,payload,updated_revision,deleted FROM segments "
                    "WHERE session=? AND deleted=0 AND start BETWEEN ? AND ? "
                    "ORDER BY start,parent LIMIT 8", (session, left, right),
                ).fetchall()
                rows_by_parent.update({r["parent"]: _segment_row(r) for r in around})
        selected = sorted(rows_by_parent.values(), key=lambda r: (r["start"], r["parent"]))
        return selected, len(selected), hit_parents

    def _response(self, session: str, metadata: dict[str, Any], revision: int,
                  mode: str, rows: list[dict[str, Any]], total: int, offset: int,
                  *, query: str | None = None, current: bool = False,
                  next_offset: int | None = None, after_revision: int | None = None,
                  next_revision: int | None = None,
                  priority_parents: set[str] | None = None,
                  page_kind: str | None = None) -> dict[str, Any]:
        data: dict[str, Any] = {
            "status": "ok", "session": session, "revision": revision,
            "meeting": _safe_metadata(metadata), "response_mode": mode,
            "freshness": {
                "updated_at": metadata.get("updated_at"),
                "max_transcribed_end": None,
                "partial_count": 0,
                "sources": [],
            },
            "coverage": {"returned_rows": 0, "total_rows": total, "offset": offset,
                         "truncated": False},
            "segments": [],
        }
        if metadata.get("projection_updating"):
            data["status"] = "updating"
            data["projection_state"] = "committed_text_pending_speaker_projection"
            data["speaker_labels_verified"] = False
            data["coverage"]["scope"] = "last_committed_projection"
            # Names can be stale during a correction. Keep committed words and
            # timings readable, but do not publish the old person's name.
            for row in rows:
                for turn in row.get("turns", []):
                    for value in [turn, *turn.get("parts", [])]:
                        _mask_stale_speaker(value)
        if current:
            data["advisory"] = {"first_answer_target_seconds": 30,
                                "followup_budget_seconds": 90}
        if query:
            data["query"] = query[:200]
        if after_revision is not None:
            data["after_revision"] = after_revision
        if next_revision is not None:
            data["next_revision"] = next_revision
        if next_offset is not None:
            data["next_offset"] = next_offset if next_offset < total + offset else None
        if page_kind == "read":
            data["next_offset"] = offset
        # Keep matching and newest rows first while selecting, then restore
        # chronological order for the Agent. A giant row is made explicitly
        # partial and receives continuation tokens instead of stalling a page.
        priority = priority_parents or set()
        if current or priority:
            selection = sorted(rows, key=lambda r: (0 if r["parent"] in priority else 1,
                                                      -r["start"], r["parent"]))
        else:
            selection = list(rows)
        for row in selection:
            self._check_deadline()
            candidate = dict(data)
            candidate["segments"] = [*data["segments"], row]
            candidate["coverage"] = dict(data["coverage"], returned_rows=len(candidate["segments"]))
            if _encoded_len(candidate) <= MAX_OUTPUT_CHARS - 1024:
                data = candidate
                continue
            partial, cursors = _fit_row_for_response(row, data, MAX_OUTPUT_CHARS - 1024,
                                                     session=session)
            if partial is None:
                data["coverage"]["truncated"] = True
                if page_kind in {"read", "changes"} and not data["segments"]:
                    # A malformed oversized structure must still make page
                    # progress; expose a marker with a row continuation.
                    partial, cursors = _minimal_row(row, session)
                else:
                    if page_kind in {"read", "changes"}:
                        break
                    continue
            candidate = dict(data)
            candidate["segments"] = [*data["segments"], partial]
            candidate["coverage"] = dict(data["coverage"], returned_rows=len(candidate["segments"]))
            if cursors:
                candidate["continuations"] = [*data.get("continuations", []), *cursors]
            if _encoded_len(candidate) > MAX_OUTPUT_CHARS - 1024:
                data["coverage"]["truncated"] = True
                if page_kind in {"read", "changes"}:
                    break
                continue
            data = candidate
            data["coverage"]["truncated"] = True
            if page_kind in {"read", "changes"}:
                # The row is represented by a marked prefix. Page position
                # advances, while text/turn continuations preserve the rest.
                break
        if priority or current:
            data["segments"].sort(key=lambda r: (r["start"], r["parent"]))
        delivered = data["segments"]
        max_end = None
        partial_count = 0
        sources: set[str] = set()
        for row in delivered:
            if row.get("deleted"):
                continue
            if row.get("end") is not None:
                max_end = row["end"] if max_end is None else max(max_end, row["end"])
            for turn in row.get("turns", []):
                if not turn.get("final", False):
                    partial_count += 1
                if turn.get("source"):
                    sources.add(turn["source"])
        data["freshness"].update({"max_transcribed_end": max_end,
                                  "partial_count": partial_count,
                                  "sources": sorted(sources)[:8]})
        if offset + data["coverage"]["returned_rows"] < total:
            data["coverage"]["truncated"] = True
        if page_kind == "read":
            data["next_offset"] = offset + data["coverage"]["returned_rows"]
            if data["next_offset"] >= total:
                data["next_offset"] = None
        if after_revision is not None:
            delivered_revisions = [row["updated_revision"] for row in delivered]
            data["next_revision"] = max(delivered_revisions, default=after_revision)
        self._check_deadline()
        return data

    def _read_continuation(self, session: str, metadata: dict[str, Any], revision: int,
                           token: dict[str, Any]) -> dict[str, Any]:
        parent = token.get("parent")
        if not isinstance(parent, str):
            raise ContextError("invalid_cursor")
        raw = self.conn.execute(
            "SELECT parent,revision,start,end,payload,updated_revision,deleted FROM segments "
            "WHERE session=? AND parent=? AND deleted=0", (session, parent),
        ).fetchone()
        if not raw:
            raise ContextError("continuation_source_changed")
        row = _segment_row(raw)
        if token.get("parent_revision") != row["revision"]:
            raise ContextError("continuation_source_changed")
        if token["kind"] in {"text", "texts"}:
            cursor_kind = token["kind"]
            if cursor_kind == "texts":
                paths = token.get("paths")
                path_index = token.get("index")
                if not isinstance(paths, list) or not isinstance(path_index, int) or not 0 <= path_index < len(paths):
                    raise ContextError("invalid_cursor")
                path = paths[path_index]
            else:
                paths, path_index = [], 0
                path = token.get("path")
            offset = token.get("offset")
            if not isinstance(path, str) or not isinstance(offset, int) or offset < 0:
                raise ContextError("invalid_cursor")
            text = _text_at_path(row, path)
            if text is None or offset > len(text):
                raise ContextError("continuation_source_changed")
            chunk = text[offset:offset + 6000]
            next_offset = offset + len(chunk)
            result = {"status": "ok", "session": session, "revision": revision,
                      "continuation_chunk": {"kind": "text", "parent": parent,
                                             "field": path, "offset": offset,
                                             "total_chars": len(text), "text": chunk}}
            if next_offset < len(text):
                next_token = dict(token, offset=next_offset)
            elif cursor_kind == "texts" and path_index + 1 < len(paths):
                next_token = dict(token, index=path_index + 1, offset=0)
            else:
                next_token = None
            result["next_cursor"] = _encode_cursor(next_token) if next_token else None
            return result
        kind = token["kind"]
        index = token.get("index")
        if not isinstance(index, int) or index < 0:
            raise ContextError("invalid_cursor")
        if kind == "turns":
            items = row["turns"]
        else:
            turn_index = token.get("turn_index")
            if not isinstance(turn_index, int) or not 0 <= turn_index < len(row["turns"]):
                raise ContextError("continuation_source_changed")
            items = row["turns"][turn_index].get("parts", [])
        if index >= len(items):
            raise ContextError("continuation_source_changed")
        item = copy.deepcopy(items[index])
        chunk_row = {"parent": parent, "revision": row["revision"], "start": row["start"],
                     "end": row["end"], "updated_revision": row["updated_revision"],
                     "deleted": False, "turns": [item] if kind == "turns" else
                     [{"parts": [item]}]}
        partial, text_cursors = _fit_row_for_response(chunk_row, {"segments": []}, MAX_OUTPUT_CHARS - 500,
                                                      session=session)
        if partial is None:
            raise ContextError("continuation_item_unavailable")
        emitted = partial["turns"][0] if kind == "turns" else partial["turns"][0]["parts"][0]
        result = {"status": "ok", "session": session, "revision": revision,
                  "continuation_chunk": {"kind": kind, "parent": parent,
                                         "index": index, "item": emitted}}
        if text_cursors:
            adjusted = []
            for cursor_value in text_cursors:
                nested = _decode_cursor(cursor_value)
                if nested.get("kind") == "texts":
                    if kind == "turns":
                        nested["paths"] = [path.replace("turns/0/", f"turns/{index}/", 1)
                                           for path in nested.get("paths", [])]
                    else:
                        nested["paths"] = [path.replace("turns/0/parts/0/",
                                                        f"turns/{turn_index}/parts/{index}/", 1)
                                           for path in nested.get("paths", [])]
                elif nested.get("kind") == "text":
                    nested_path = nested.get("path", "")
                    if kind == "turns":
                        nested["path"] = nested_path.replace("turns/0/", f"turns/{index}/", 1)
                    else:
                        nested["path"] = nested_path.replace("turns/0/parts/0/",
                                                             f"turns/{turn_index}/parts/{index}/", 1)
                elif nested.get("kind") == "parts" and kind == "turns":
                    nested["turn_index"] = index
                adjusted.append(_encode_cursor(nested))
            result["continuations"] = adjusted
        next_cursor = None
        if index + 1 < len(items):
            next_cursor = dict(token, index=index + 1)
        result["next_cursor"] = _encode_cursor(next_cursor) if next_cursor else None
        return result

    def _recording_only(self, session: str, metadata: dict[str, Any], revision: int) -> dict[str, Any]:
        return {"status": "recording_only", "session": session, "revision": revision,
                "meeting": _safe_metadata(metadata), "segments": [],
                "message": "transcript_context_unavailable_for_local_only_recording"}

    def _updating(self, session: str, revision: int, metadata: dict[str, Any]) -> dict[str, Any]:
        return {
            "status": "updating", "session": session, "revision": revision,
            "meeting": _safe_metadata(metadata), "response_mode": self._mode(session, metadata),
            "segments": [], "coverage": {"returned_rows": 0, "total_rows": None,
                                           "truncated": False},
        }


def _note_clock(clock: Any, relative: float) -> str:
    """Use the latest capture anchor, displayed in the archive's Shanghai timezone."""
    try:
        if (not isinstance(clock, dict) or clock.get("schema") != 1
                or clock.get("basis") != "capture_clock"
                or not isinstance(clock.get("anchors"), list)
                or not 1 <= len(clock["anchors"]) <= 10000):
            raise ValueError()
        zone = ZoneInfo("Asia/Shanghai")
        selected = None
        previous = -1.0
        for anchor in clock["anchors"]:
            start, unix = anchor["relative_start"], anchor["unix_time"]
            if (type(start) not in (int, float) or type(unix) not in (int, float)
                    or not math.isfinite(start) or not math.isfinite(unix)
                    or not 0 <= start <= 86400 or start < previous or unix <= 0):
                raise ValueError()
            previous = start
            if start <= relative + 1e-7:
                selected = (start, unix)
        if selected is None:
            raise ValueError()
        return datetime.fromtimestamp(selected[1] + relative - selected[0], zone).strftime("%H:%M:%S")
    except (KeyError, TypeError, ValueError, OverflowError, OSError, ZoneInfoNotFoundError) as exc:
        raise ContextError("note_clock_unavailable") from exc


def _safe_metadata(metadata: dict[str, Any]) -> dict[str, Any]:
    keys = ("session", "title", "phase", "local_only", "projection_updating",
            "recording_elapsed_seconds", "updated_at", "writer_id", "asr_states",
            "transcription_complete")
    result = {}
    for key in keys:
        if key not in metadata:
            continue
        value = metadata[key]
        result[key] = value[:300] if isinstance(value, str) else value
    recovery = metadata.get("recording_recovery")
    if isinstance(recovery, dict) and recovery.get("kind") == "interrupted_capture":
        # Expose recovery provenance, never arbitrary local paths or audio.
        safe = {"kind": "interrupted_capture"}
        for key in ("state", "code", "audio_files_preserved", "gapless_capture_verified",
                    "transcript_modified", "transcription_started"):
            value = recovery.get(key)
            if isinstance(value, (str, bool)):
                safe[key] = value[:160] if isinstance(value, str) else value
        warnings = recovery.get("warnings", [])
        tracks = recovery.get("tracks", [])
        safe["warnings"] = [v[:500] for v in (warnings if isinstance(warnings, list) else [])
                            if isinstance(v, str)][:32]
        safe["tracks"] = [
            {k: v for k, v in row.items()
             if (k == "track" and isinstance(v, str) and len(v) < 100)
             or (k in {"before_bytes", "verified_bytes", "verified_tail_bytes"}
                 and type(v) is int and v >= 0)}
            for row in (tracks if isinstance(tracks, list) else []) if isinstance(row, dict)
        ][:64]
        result["recording_recovery"] = safe
    return result


def _segment_row(row: sqlite3.Row) -> dict[str, Any]:
    parent = row["parent"]
    if not isinstance(parent, str) or len(parent) > 300:
        raise ContextError("invalid_segment_parent")
    try:
        payload = json.loads(row["payload"])
    except (TypeError, json.JSONDecodeError) as exc:
        raise ContextError("invalid_segment_payload") from exc
    if not isinstance(payload, list):
        raise ContextError("invalid_segment_payload")
    safe_turns = [_safe_turn(turn) for turn in payload]
    return {
        "parent": parent, "revision": row["revision"],
        "start": row["start"], "end": row["end"], "updated_revision": row["updated_revision"],
        "deleted": bool(row["deleted"]), "turns": safe_turns,
    }


def _safe_turn(turn: Any) -> dict[str, Any]:
    if not isinstance(turn, dict):
        raise ContextError("invalid_segment_payload")
    keys = ("id", "parent", "text", "speaker", "speaker_confirmed", "speaker_name_origin", "uncertain", "final",
            "start", "end", "absolute_start", "absolute_end", "source", "parts")
    safe: dict[str, Any] = {}
    for key in keys:
        if key not in turn:
            continue
        value = turn[key]
        if key in {"text"} and isinstance(value, str):
            safe[key] = value
        elif key == "speaker_name_origin":
            safe[key] = value if isinstance(value, str) and value in {"manual", "voiceprint", "semantic", "anonymous", "mixed"} else "anonymous"
        elif key == "parts" and isinstance(value, list):
            safe[key] = [_safe_part(part) for part in value]
        elif key in {"speaker_confirmed", "uncertain", "final"}:
            safe[key] = bool(value)
        elif key in {"start", "end"}:
            safe[key] = value if value is None or isinstance(value, (int, float)) else None
        elif key in {"id", "parent", "speaker", "absolute_start", "absolute_end", "source"}:
            cap = 80 if key == "source" else 300
            safe[key] = value[:cap] if isinstance(value, str) else None
    safe.setdefault("text", "")
    safe.setdefault("parts", [])
    safe.setdefault("final", False)
    reference = _shared_person_reference(turn)
    parts = safe["parts"]
    if (reference and not safe.get("uncertain", False) and parts
            and all({key: part.get(key) for key in reference} == reference for part in parts)):
        safe.update(reference)
    return safe


def _safe_part(part: Any) -> dict[str, Any]:
    if not isinstance(part, dict):
        raise ContextError("invalid_segment_payload")
    out: dict[str, Any] = {}
    for key in ("id", "text", "speaker", "speaker_confirmed", "speaker_name_origin", "start", "end"):
        if key not in part:
            continue
        value = part[key]
        if key == "text" and isinstance(value, str):
            out[key] = value
        elif key == "speaker_name_origin":
            out[key] = value if isinstance(value, str) and value in {"manual", "voiceprint", "semantic", "anonymous"} else "anonymous"
        elif key == "speaker_confirmed":
            out[key] = bool(value)
        elif key in {"start", "end"}:
            out[key] = value if value is None or isinstance(value, (int, float)) else None
        elif key in {"id", "speaker"}:
            out[key] = value[:300] if isinstance(value, str) else None
    out.update(_shared_person_reference(part))
    return out


def _shared_person_reference(value: dict[str, Any]) -> dict[str, Any]:
    """Accept a sourced manual link, never an automatic voice-profile UUID."""
    person_id = value.get("shared_person_id")
    evidence = value.get("shared_person_evidence")
    if (value.get("speaker_confirmed") is not True
            or value.get("speaker_name_origin") != "manual"
            or not isinstance(person_id, str)
            or re.fullmatch(r"person:[0-9a-f]{20}", person_id) is None
            or not isinstance(evidence, list) or not 1 <= len(evidence) <= 8
            or any(not isinstance(item, str) or not item.strip() or len(item) > 2048
                   or any(unicodedata.category(char) in {"Cc", "Cf"} for char in item)
                   for item in evidence)):
        return {}
    return {"shared_person_id": person_id, "shared_person_evidence": list(evidence)}


def _mask_stale_speaker(value: dict[str, Any]) -> None:
    value["speaker"] = "待确认"
    value["speaker_confirmed"] = False
    value["speaker_name_origin"] = "anonymous"
    value.pop("shared_person_id", None)
    value.pop("shared_person_evidence", None)


def _encoded_len(value: dict[str, Any]) -> int:
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def _encode_cursor(value: dict[str, Any]) -> str:
    raw = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _decode_cursor(token: str) -> dict[str, Any]:
    if not isinstance(token, str) or len(token) > 2048 or not re.fullmatch(r"[A-Za-z0-9_-]+", token):
        raise ContextError("invalid_cursor")
    try:
        raw = base64.urlsafe_b64decode(token + "=" * (-len(token) % 4))
        value = json.loads(raw)
    except (ValueError, json.JSONDecodeError) as exc:
        raise ContextError("invalid_cursor") from exc
    if not isinstance(value, dict):
        raise ContextError("invalid_cursor")
    return value


def _text_paths(row: dict[str, Any]) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    for ti, turn in enumerate(row.get("turns", [])):
        if isinstance(turn.get("text"), str):
            found.append((f"turns/{ti}/text", turn["text"]))
        for pi, part in enumerate(turn.get("parts", [])):
            if isinstance(part.get("text"), str):
                found.append((f"turns/{ti}/parts/{pi}/text", part["text"]))
    return found


def _text_at_path(row: dict[str, Any], path: str) -> str | None:
    pieces = path.split("/")
    try:
        if len(pieces) == 3 and pieces[0] == "turns" and pieces[2] == "text":
            value = row["turns"][int(pieces[1])]["text"]
        elif len(pieces) == 5 and pieces[0] == "turns" and pieces[2] == "parts" and pieces[4] == "text":
            value = row["turns"][int(pieces[1])]["parts"][int(pieces[3])]["text"]
        else:
            return None
    except (IndexError, KeyError, ValueError, TypeError):
        return None
    return value if isinstance(value, str) else None


def _set_text_path(row: dict[str, Any], path: str, value: str,
                   *, total_chars: int, truncated: bool) -> None:
    pieces = path.split("/")
    target: dict[str, Any]
    if len(pieces) == 3:
        target = row["turns"][int(pieces[1])]
    else:
        target = row["turns"][int(pieces[1])]["parts"][int(pieces[3])]
    target["text"] = value
    if truncated:
        target["text_truncated"] = True
        target["text_total_chars"] = total_chars


def _fit_row_for_response(row: dict[str, Any], base: dict[str, Any], budget: int,
                          *, session: str = "") -> tuple[dict[str, Any] | None, list[str]]:
    candidate = copy.deepcopy(row)
    limit = 4000
    continuations: dict[str, int] = {}
    for _ in range(12):
        candidate = copy.deepcopy(row)
        continuations = {}
        for path, original in _text_paths(candidate):
            if len(original) > limit:
                _set_text_path(candidate, path, original[:limit], total_chars=len(original), truncated=True)
                continuations[path] = limit
        wrapped = dict(base)
        wrapped["segments"] = [*base.get("segments", []), candidate]
        if _encoded_len(wrapped) <= budget:
            tokens = []
            if continuations:
                paths = list(continuations)
                tokens.append(_encode_cursor({"kind": "texts", "session": session,
                                              "parent": row["parent"], "paths": paths,
                                              "parent_revision": row["revision"],
                                              "index": 0, "offset": continuations[paths[0]]}))
            return candidate, tokens
        limit //= 2
        if limit == 0:
            break
    # When a parent contains many turns, keep a prefix and provide a cursor for
    # the omitted turns. Text truncation cursors remain independently usable.
    for keep in (max(1, len(row.get("turns", [])) // 2), 1, 0):
        candidate = copy.deepcopy(row)
        original_turns = candidate.get("turns", [])
        total_turns = len(original_turns)
        candidate["turns"] = original_turns[:keep]
        continuations = []
        if keep < total_turns:
            candidate["turns_truncated"] = True
            candidate["turns_total"] = total_turns
            continuations.append(_encode_cursor({"kind": "turns", "session": session,
                                                  "parent": row["parent"],
                                                  "parent_revision": row["revision"], "index": keep}))
        for ti, turn in enumerate(candidate["turns"]):
            original_parts = turn.get("parts", [])
            parts_total = len(original_parts)
            if not parts_total:
                continue
            for part_keep in (max(1, parts_total // 2), 1, 0):
                turn["parts"] = original_parts[:part_keep]
                wrapped = dict(base)
                wrapped["segments"] = [*base.get("segments", []), candidate]
                if _encoded_len(wrapped) <= budget:
                    break
            if part_keep < parts_total:
                turn["parts_truncated"] = True
                turn["parts_total"] = parts_total
                continuations.append(_encode_cursor({"kind": "parts", "session": session,
                                                      "parent": row["parent"], "turn_index": ti,
                                                      "parent_revision": row["revision"],
                                                      "index": part_keep}))
        wrapped = dict(base)
        wrapped["segments"] = [*base.get("segments", []), candidate]
        if _encoded_len(wrapped) <= budget:
            return candidate, continuations
    return None, []


def _minimal_row(row: dict[str, Any], session: str) -> tuple[dict[str, Any], list[str]]:
    candidate = {key: row.get(key) for key in
                 ("parent", "revision", "start", "end", "updated_revision", "deleted")}
    candidate.update({"turns": [], "turns_truncated": True,
                      "turns_total": len(row.get("turns", []))})
    cursors = [_encode_cursor({"kind": "turns", "session": session,
                               "parent": row["parent"], "parent_revision": row["revision"],
                               "index": 0})]
    return candidate, cursors


def _query_terms(query: str) -> list[str]:
    q = query.strip()[:200]
    # CJK text is searched by overlapping bigrams (plus a single char for short
    # input); Latin text is searched by words. This avoids treating a whole
    # Chinese sentence as a single exact substring.
    terms: list[str] = []
    for chunk in re.findall(r"[\u3400-\u9fff]+|[A-Za-z0-9_]+", q):
        if re.fullmatch(r"[\u3400-\u9fff]+", chunk):
            terms.extend([chunk] if len(chunk) <= 2 else [chunk[i:i + 2] for i in range(len(chunk) - 1)])
        else:
            terms.append(chunk)
    # Bound SQL complexity, preserve order and remove duplicate terms.
    return list(dict.fromkeys(term for term in terms if term))[:24]


def _like_pattern(term: str) -> str:
    escaped = term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


def _merge_rows(first: list[dict[str, Any]], second: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged = {row["parent"]: row for row in first}
    merged.update({row["parent"]: row for row in second})
    return sorted(merged.values(), key=lambda row: (row["start"], row["parent"]))


def _validate_session(session: str) -> None:
    if not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", session):
        raise ContextError("invalid_session")


def _validate_page(offset: int, limit: int) -> None:
    if offset < 0 or limit < 1:
        raise ContextError("invalid_page")


def _state_is_live(state: dict[str, Any], now: float) -> bool:
    pid, heartbeat = state.get("pid"), state.get("heartbeat")
    if not isinstance(pid, int) or pid <= 0 or not isinstance(heartbeat, (int, float)):
        return False
    if now - float(heartbeat) > CURRENT_MAX_AGE_SECONDS or float(heartbeat) > now + 5:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    except OSError:
        return False
    return True


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Read the current 在场 meeting context (read-only).")
    parser.add_argument("--database", type=Path, help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest="command", required=True)
    current = sub.add_parser("current", help="Read only the explicitly active meeting.")
    current.add_argument("--query")
    read = sub.add_parser("read", help="Read a pinned meeting page.")
    read.add_argument("--session", required=True)
    read.add_argument("--offset", type=int, default=0)
    read.add_argument("--limit", type=int, default=60)
    read.add_argument("--cursor", help=argparse.SUPPRESS)
    search = sub.add_parser("search", help="Search a pinned meeting and nearby context.")
    search.add_argument("--session", required=True)
    search.add_argument("--query", required=True)
    search.add_argument("--limit", type=int, default=20)
    changes = sub.add_parser("changes", help="Read revisions and deletions after a meeting revision.")
    changes.add_argument("--session", required=True)
    changes.add_argument("--after-revision", type=int, required=True)
    changes.add_argument("--limit", type=int, default=60)
    changes.add_argument("--cursor", help=argparse.SUPPRESS)
    return parser


def _deadline_signal(_signum: int, _frame: Any) -> None:
    raise ContextError("read_deadline_exceeded")


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    previous_handler = None
    previous_timer = (0.0, 0.0)
    alarm_started = time.monotonic()
    alarm_enabled = False
    try:
        previous_handler = signal.getsignal(signal.SIGALRM)
        previous_timer = signal.getitimer(signal.ITIMER_REAL)
        signal.signal(signal.SIGALRM, _deadline_signal)
        signal.setitimer(signal.ITIMER_REAL, DEADLINE_SECONDS)
        alarm_enabled = True
    except (AttributeError, ValueError, OSError):
        # Direct Reader users still get SQLite progress and monotonic checks.
        alarm_enabled = False
    try:
        reader = Reader(args.database or DEFAULT_DB)
        try:
            if args.command == "current":
                result = reader.current(args.query)
            elif args.command == "read":
                result = reader.read(args.session, args.offset, args.limit, args.cursor)
            elif args.command == "search":
                result = reader.search(args.session, args.query, args.limit)
            else:
                result = reader.changes(args.session, args.after_revision, args.limit, args.cursor)
        finally:
            reader.close()
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0
    except ContextError as exc:
        print(json.dumps({"status": "error", "error": str(exc)}, ensure_ascii=False))
        return 2
    except sqlite3.Error:
        print(json.dumps({"status": "error", "error": "database_busy_or_unavailable"}))
        return 2
    finally:
        if alarm_enabled:
            remaining = max(0.0, previous_timer[0] - (time.monotonic() - alarm_started))
            signal.setitimer(signal.ITIMER_REAL, remaining, previous_timer[1])
            signal.signal(signal.SIGALRM, previous_handler)


if __name__ == "__main__":
    raise SystemExit(main())
