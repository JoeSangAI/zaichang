#!/usr/bin/env python3
"""Prepare a reversible, read-only-source merge package for two SessionCache records.

This tool never edits SessionCache. It copies both complete source folders into an
isolated staging package and writes a time-aligned transcript projection there.
The original per-session files remain the rollback source of truth.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import shutil
import stat
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CACHE_ROOT = Path.home() / "Library/Application Support/MeetingAssistant/SessionCache"
DEFAULT_STAGE_ROOT = PROJECT_ROOT / ".runtime/session-continuity-1012/merge-staging"
EXPECTED = {
    "D2909AA6-B97C-4AA7-83AD-506F47CABA67": "点位筛选与投放节奏｜单周滚动策略下高入住率楼盘点位可得性验证",
    "2931F606-7911-46ED-8200-40038FA5896F": "投放排期｜11月7日启动的可行性验证",
}


def _merged_ids(first_id: str, second_id: str) -> tuple[str, str]:
    cache_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"zaichang-cache:effective-mic-v4:{first_id}:{second_id}"))
    session = str(uuid.uuid5(uuid.NAMESPACE_URL, f"zaichang-session:effective-mic-v4:{first_id}:{second_id}"))
    return cache_id, session


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected JSON object: {path.name}")
    return value


def _walk_files(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Refusing symlink in source cache: {path}")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = sha256(path)
    return result


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temp.open("xb") as stream:
            stream.write(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode("utf-8") + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        temp.unlink(missing_ok=True)


def _app_lock_path(app_info: Path) -> Path:
    try:
        info = plistlib.loads(app_info.read_bytes())
        lock_path = info["AppLockPath"]
    except Exception as exc:
        raise ValueError(f"Cannot read official AppLockPath from {app_info}") from exc
    if not isinstance(lock_path, str) or not lock_path.startswith("/"):
        raise ValueError("AppLockPath must be an absolute path from the selected app Info.plist")
    return Path(lock_path)


def _try_app_lock(lock_path: Path) -> tuple[int | None, str]:
    """Non-blocking lock using the same inode/path consumed by the desktop UI."""
    flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(lock_path, flags)
    except FileNotFoundError:
        return None, "lock_file_missing"
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        os.close(descriptor)
        raise ValueError("App lock must be an owned regular file")
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        return None, "official_app_lock_busy"
    return descriptor, "available"


def _validate_import_package(cache_root: Path, package: Path) -> tuple[dict[str, Any], Path, dict[str, str]]:
    stage_root = DEFAULT_STAGE_ROOT.resolve()
    resolved_package = package.resolve(strict=True)
    if stage_root not in resolved_package.parents:
        raise ValueError("Import package must be inside the project merge-staging directory")
    manifest = read_json(resolved_package / "merge-manifest.json")
    sources = manifest.get("sources")
    if not isinstance(sources, list) or [row.get("cache_id") for row in sources] != list(EXPECTED):
        raise ValueError("Staging manifest does not name exactly the two selected meetings in order")
    cache_id = manifest.get("app_cache", {}).get("cache_id")
    expected_id, expected_session = _merged_ids(*EXPECTED.keys())
    if cache_id != expected_id or manifest.get("merge_session") != expected_session:
        raise ValueError("Unexpected merged cache identity")
    app_meta = manifest["app_cache"]
    if app_meta.get("title") != "点位筛选与投放排期｜11月7日启动可行性验证":
        raise ValueError("Unexpected merged recording title")
    folder_rel = Path(app_meta.get("folder", ""))
    if folder_rel.as_posix() != f"merged_recording/{cache_id}":
        raise ValueError("Invalid merged cache path in staging manifest")
    merged = (resolved_package / folder_rel).resolve(strict=True)
    if resolved_package not in merged.parents:
        raise ValueError("Merged cache escaped the staging package")
    expected_cache_hashes = app_meta.get("files_sha256")
    if not isinstance(expected_cache_hashes, dict) or _walk_files(merged) != expected_cache_hashes:
        raise ValueError("Staged merged cache files do not match their manifest hashes")

    sources_root = resolved_package / "sources"
    for row in sources:
        cache_id_source = row.get("cache_id")
        if cache_id_source not in EXPECTED or row.get("title") != EXPECTED[cache_id_source]:
            raise ValueError("Unexpected source title or ID in staging manifest")
        expected = row.get("files_sha256")
        source_copy = sources_root / cache_id_source
        source_live = cache_root / cache_id_source
        if not isinstance(expected, dict) or _walk_files(source_copy) != expected:
            raise ValueError(f"Staged source backup hash mismatch: {cache_id_source}")
        if source_live.is_symlink() or not source_live.is_dir() or _walk_files(source_live) != expected:
            raise ValueError(f"Live source changed since staging: {cache_id_source}")
        display = read_json(source_live / "display-info.json")
        if display.get("title") != EXPECTED[cache_id_source]:
            raise ValueError(f"Live source title changed: {cache_id_source}")
    return manifest, merged, expected_cache_hashes


def _import_layout(cache_root: Path, cache_id: str) -> tuple[Path, Path, Path]:
    target = cache_root / cache_id
    temp = cache_root / f".{cache_id}.importing"
    originals = cache_root / ".merged-originals" / cache_id
    return target, temp, originals


def _validate_originals_parent(cache_root: Path) -> Path:
    parent = cache_root / ".merged-originals"
    if parent.is_symlink():
        raise ValueError("Rollback parent must not be a symlink")
    if parent.exists() and not parent.is_dir():
        raise ValueError("Rollback parent exists but is not a directory")
    return parent


def _import_receipt(cache_root: Path, manifest: dict[str, Any], state: str,
                    moved_sources: list[str]) -> dict[str, Any]:
    return {
        "schema": 1,
        "kind": "zaichang-sessioncache-merge-import",
        "state": state,
        "merged_cache_id": manifest["app_cache"]["cache_id"],
        "merged_title": manifest["app_cache"]["title"],
        "merged_files_sha256": manifest["app_cache"]["files_sha256"],
        "sources": [{"cache_id": row["cache_id"], "title": row["title"],
                     "files_sha256": row["files_sha256"]} for row in manifest["sources"]],
        "moved_sources": moved_sources,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }


def import_staged(cache_root: Path, package: Path, app_info: Path, *, apply: bool = False) -> dict[str, Any]:
    manifest, staged_cache, expected_cache_hashes = _validate_import_package(cache_root, package)
    cache_id = manifest["app_cache"]["cache_id"]
    target, temp, originals = _import_layout(cache_root, cache_id)
    _validate_originals_parent(cache_root)
    if target.exists() or target.is_symlink():
        raise FileExistsError(f"Merged cache destination already exists: {target}")
    if temp.exists() or temp.is_symlink():
        raise FileExistsError(f"Import temporary destination already exists: {temp}")
    if originals.exists() or originals.is_symlink():
        raise FileExistsError(f"Rollback destination already exists: {originals}")
    lock_path = _app_lock_path(app_info)
    lock_fd, lock_status = _try_app_lock(lock_path)
    if not apply:
        if lock_fd is not None:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
        return {"mode": "dry-run", "lock_path": str(lock_path), "lock_status": lock_status,
                "merged_cache_id": cache_id, "merged_title": manifest["app_cache"]["title"],
                "merged_destination": str(target), "rollback_destination": str(originals),
                "source_ids": [row["cache_id"] for row in manifest["sources"]],
                "source_hashes_revalidated": True, "staging_hashes_revalidated": True,
                "writes_performed": False,
                "next_action": "rerun with --apply-import after the official app is quit and the lock is available"}
    if lock_fd is None:
        raise RuntimeError(f"Cannot import while the official app lock is unavailable: {lock_status}")

    moved: list[str] = []
    target_created = False
    receipt_path = originals / "import-receipt.json"
    try:
        # Recheck all mutation preconditions after taking the lock.
        manifest, staged_cache, expected_cache_hashes = _validate_import_package(cache_root, package)
        target, temp, originals = _import_layout(cache_root, cache_id)
        if target.exists() or temp.exists() or originals.exists():
            raise FileExistsError("An import destination appeared after preflight")
        shutil.copytree(staged_cache, temp, symlinks=False)
        if _walk_files(temp) != expected_cache_hashes:
            raise IOError("Copied merged cache failed its manifest hash check")

        originals.mkdir(parents=True, exist_ok=False)
        _atomic_json(receipt_path, _import_receipt(cache_root, manifest, "prepared", moved))
        for row in manifest["sources"]:
            source_id = row["cache_id"]
            source = cache_root / source_id
            backup = originals / source_id
            if _walk_files(source) != row["files_sha256"]:
                raise ValueError(f"Source changed immediately before move: {source_id}")
            os.replace(source, backup)
            moved.append(source_id)
            _atomic_json(receipt_path, _import_receipt(cache_root, manifest, "moving_sources", moved))

        os.replace(temp, target)
        target_created = True
        _atomic_json(receipt_path, _import_receipt(cache_root, manifest, "complete", moved))
        return {"mode": "imported", "merged_cache_id": cache_id, "merged_title": manifest["app_cache"]["title"],
                "merged_destination": str(target), "rollback_destination": str(originals),
                "receipt": str(receipt_path), "source_ids": moved,
                "merged_hashes_verified": _walk_files(target) == expected_cache_hashes,
                "writes_performed": True}
    except BaseException:
        # Best-effort synchronous rollback; the durable receipt also identifies
        # every completed move if the process is interrupted between steps.
        if target_created and target.exists() and _walk_files(target) == expected_cache_hashes:
            shutil.rmtree(target)
        if temp.exists():
            shutil.rmtree(temp)
        for source_id in reversed(moved):
            source = cache_root / source_id
            backup = originals / source_id
            if backup.exists() and not source.exists():
                os.replace(backup, source)
        if originals.exists():
            # A leftover receipt is useful only if some source could not be
            # restored. Clear it after a complete synchronous rollback.
            if all((cache_root / source_id).exists() for source_id in moved):
                receipt_path.unlink(missing_ok=True)
                if not any(originals.iterdir()):
                    shutil.rmtree(originals)
        raise
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def rollback_import(cache_root: Path, merged_id: str, app_info: Path) -> dict[str, Any]:
    expected_id, _ = _merged_ids(*EXPECTED.keys())
    if merged_id != expected_id:
        raise ValueError("Rollback is restricted to this explicitly selected merged recording")
    lock_path = _app_lock_path(app_info)
    lock_fd, status = _try_app_lock(lock_path)
    if lock_fd is None:
        raise RuntimeError(f"Cannot rollback while the official app lock is unavailable: {status}")
    try:
        originals = cache_root / ".merged-originals" / merged_id
        _validate_originals_parent(cache_root)
        receipt_path = originals / "import-receipt.json"
        receipt = read_json(receipt_path)
        if receipt.get("kind") != "zaichang-sessioncache-merge-import" or receipt.get("merged_cache_id") != merged_id:
            raise ValueError("Missing or invalid merge import receipt")
        rows = receipt.get("sources")
        if not isinstance(rows, list) or [row.get("cache_id") for row in rows] != list(EXPECTED):
            raise ValueError("Receipt does not authorize exactly the two selected sources")
        target = cache_root / merged_id
        if target.exists():
            if _walk_files(target) != receipt.get("merged_files_sha256"):
                raise ValueError("Merged cache changed since import; refusing destructive rollback")
        for row in rows:
            source_id = row["cache_id"]
            source = cache_root / source_id
            backup = originals / source_id
            if source.exists() and _walk_files(source) != row["files_sha256"]:
                raise ValueError(f"Source destination occupied by changed data: {source_id}")
            if backup.exists() and _walk_files(backup) != row["files_sha256"]:
                raise ValueError(f"Rollback source backup hash mismatch: {source_id}")
            if not source.exists() and not backup.exists():
                raise ValueError(f"Both original source copies are missing: {source_id}")
            if source.exists() and backup.exists():
                raise ValueError(f"Both original source locations exist; inspect before rollback: {source_id}")
        if target.exists():
            shutil.rmtree(target)
        restored = []
        for row in rows:
            source_id = row["cache_id"]
            source = cache_root / source_id
            backup = originals / source_id
            if backup.exists():
                os.replace(backup, source)
            restored.append(source_id)
        receipt_path.unlink(missing_ok=True)
        originals.rmdir()
        return {"mode": "rolled-back", "merged_cache_id": merged_id, "restored_source_ids": restored,
                "merged_cache_removed": True, "source_hashes_verified": True}
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def _validate_source(cache_root: Path, cache_id: str, expected_title: str) -> tuple[Path, dict[str, Any], dict[str, Any]]:
    try:
        normalized = str(uuid.UUID(cache_id)).upper()
    except ValueError as exc:
        raise ValueError(f"Invalid cache ID: {cache_id}") from exc
    if normalized != cache_id.upper():
        raise ValueError(f"Cache ID must be canonical UUID: {cache_id}")
    directory = cache_root / normalized
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"Missing or unsafe source cache: {normalized}")
    display = read_json(directory / "display-info.json")
    meeting = read_json(directory / "meeting.json")
    if display.get("cache_id", "").upper() != normalized:
        raise ValueError(f"display-info cache ID mismatch: {normalized}")
    if meeting.get("cache_id", "").upper() != normalized:
        raise ValueError(f"meeting cache ID mismatch: {normalized}")
    if display.get("title") != expected_title:
        raise ValueError(f"Unexpected meeting title for {normalized}")
    if display.get("state") != "ready":
        raise ValueError(f"Meeting is not ready: {normalized}")
    anchor = meeting.get("absolute_clock", {}).get("anchors", [{}])[0].get("unix_time")
    if not isinstance(anchor, (int, float)):
        raise ValueError(f"Missing absolute clock anchor: {normalized}")
    return directory, display, meeting


def _epoch_map(source_session: str, merge_session: str, epoch: str) -> str:
    """Map local diarization epochs to distinct valid UUIDs in the merged session."""
    try:
        namespace = uuid.UUID(merge_session)
    except ValueError:
        namespace = uuid.NAMESPACE_URL
    return str(uuid.uuid5(namespace, f"{source_session}:{epoch}"))


def _shift_annotation_id(value: str, offset: float) -> str:
    """Shift timestamp-derived annotation IDs while leaving segment IDs stable."""
    prefix = "model:"
    wrapped = value.startswith(prefix)
    raw = value[len(prefix):] if wrapped else value
    for marker in (":word:", ":turn:"):
        if marker not in raw:
            continue
        parent, stamp = raw.rsplit(marker, 1)
        if stamp.isdigit():
            shifted = int(int(stamp) + offset * 1000 + 0.5)
            result = f"{parent}{marker}{shifted}"
            return prefix + result if wrapped else result
    return value


def _rewrite(value: Any, *, old_session: str, new_session: str, offset: float,
             epoch_map: dict[str, str], time_fields: bool = True) -> Any:
    if isinstance(value, list):
        return [_rewrite(item, old_session=old_session, new_session=new_session,
                         offset=offset, epoch_map=epoch_map, time_fields=time_fields) for item in value]
    if isinstance(value, str):
        return _shift_annotation_id(value, offset) if time_fields and offset else value
    if not isinstance(value, dict):
        return value
    rewritten: dict[str, Any] = {}
    for key, item in value.items():
        if key == "session" and item == old_session:
            rewritten[key] = new_session
        elif key == "epoch" and isinstance(item, str):
            rewritten[key] = epoch_map.setdefault(item, _epoch_map(old_session, new_session, item))
        elif key in ("start", "end") and isinstance(item, (int, float)) and time_fields:
            rewritten[key] = item + offset
        else:
            rewritten_key = _shift_annotation_id(key, offset) if time_fields and offset else key
            rewritten[rewritten_key] = _rewrite(item, old_session=old_session, new_session=new_session,
                                                 offset=offset, epoch_map=epoch_map, time_fields=time_fields)
    return rewritten


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        if not isinstance(row, dict):
            raise ValueError(f"Invalid JSONL row at {path.name}:{line_number}")
        rows.append(row)
    return rows


def _merge_names(first: dict[str, Any], second: dict[str, Any], first_session: str,
                 second_session: str, merge_session: str, second_offset: float = 0.0) -> dict[str, Any]:
    # Names are keyed by session/source/epoch/identity. Namespace epochs before
    # concatenating arrays so identical local slot numbers cannot fuse speakers.
    epoch_maps = ({}, {})
    rewritten = []
    for names, old_session, offset, epoch_map in ((first, first_session, 0.0, epoch_maps[0]),
                                                   (second, second_session, second_offset, epoch_maps[1])):
        rewritten.append(_rewrite(names, old_session=old_session, new_session=merge_session,
                                  offset=offset, epoch_map=epoch_map, time_fields=True))
    result: dict[str, Any] = {"schema": max(int(first.get("schema", 1)), int(second.get("schema", 1))),
                              "session": merge_session}
    keys = set(rewritten[0]) | set(rewritten[1])
    keys -= {"schema", "session"}
    for key in sorted(keys):
        left, right = rewritten[0].get(key), rewritten[1].get(key)
        if isinstance(left, list) and isinstance(right, list):
            result[key] = left + right
        elif isinstance(left, dict) and isinstance(right, dict):
            merged = dict(left)
            for item_key, item_value in right.items():
                if item_key in merged and merged[item_key] != item_value:
                    raise ValueError(f"Manual annotation key collision while merging {key}")
                merged[item_key] = item_value
            result[key] = merged
        elif left in (None, {}, []) :
            result[key] = right
        elif right in (None, {}, []) or left == right:
            result[key] = left
        else:
            # A conflicting singleton is preserved per source rather than
            # silently choosing one; source copies remain authoritative.
            result[key] = {"source_1": left, "source_2": right}
    return result


def _canonical(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _digest_json(value: Any) -> str:
    return hashlib.sha256(_canonical(value)).hexdigest()


def _timeline_events(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    current: dict[str, dict[str, Any]] = {}
    discarded: set[str] = set()
    for event in rows:
        if event.get("type") == "asr_replay":
            for segment_id in event.get("discard_segment_ids", []):
                discarded.add(segment_id)
                current.pop(segment_id, None)
            continue
        if event.get("type") != "segment":
            continue
        segment_id = event.get("segment_id")
        if not isinstance(segment_id, str) or not segment_id or segment_id in discarded:
            continue
        old = current.get(segment_id)
        if old is not None:
            if old.get("session") != event.get("session"):
                continue
            if isinstance(old.get("revision"), int):
                if not isinstance(event.get("revision"), int) or event["revision"] <= old["revision"]:
                    continue
            if old.get("final") is True and event.get("final") is not True:
                continue
            if isinstance(old.get("asr_revision"), int) and isinstance(event.get("asr_revision"), int) and event["asr_revision"] < old["asr_revision"]:
                continue
        current[segment_id] = event
    return sorted(current.values(), key=lambda row: (
        float(row.get("start", float("inf"))) if isinstance(row.get("start"), (int, float)) else float("inf"),
        row["segment_id"],
    ))


def _iter_units(events: list[dict[str, Any]], source_audio_ends: dict[str, float]) -> list[dict[str, Any]]:
    starts = [(event.get("source_id"), event.get("epoch"), event.get("start")) for event in events
              if isinstance(event.get("start"), (int, float))]
    result: list[dict[str, Any]] = []
    parents: set[str] = set()
    for event in events:
        source, start, text = event.get("source_id"), event.get("start"), event.get("text")
        if not isinstance(source, str) or not isinstance(start, (int, float)) or not isinstance(text, str) or not text.strip():
            continue
        epoch = event.get("epoch")
        if event.get("final") is True and event.get("end_time_known") is True:
            end = event.get("end")
            if not isinstance(end, (int, float)) or end <= start:
                continue
            approximate = False
        else:
            candidates = [s for src, ep, s in starts if src == source and (epoch is None or ep == epoch)
                          and isinstance(s, (int, float)) and s > start]
            if source in source_audio_ends:
                candidates.append(source_audio_ends[source])
            if not candidates:
                continue
            end = min(min(candidates), start + 10)
            if end <= start:
                continue
            approximate = True
        parent = event.get("segment_id")
        if not isinstance(parent, str) or not parent or parent in parents:
            continue
        parents.add(parent)
        runs = event.get("speaker_runs") or []
        if approximate and runs and not all(
            isinstance(run.get("start"), (int, float)) and isinstance(run.get("end"), (int, float))
            and run["start"] >= start - 0.001 and run["end"] <= end + 0.001
            and run["end"] - run["start"] <= 10 for run in runs
        ):
            continue
        if runs:
            for run in runs:
                body = run.get("text")
                if not isinstance(body, str) or not body.strip():
                    continue
                start_ms = int((float(run["start"]) * 1000) + 0.5)
                result.append({"unit_id": f"{parent}:word:{start_ms}", "text": body,
                               "speaker": run.get("speaker"), "event": event})
        else:
            result.append({"unit_id": parent, "text": text, "speaker": event.get("speaker"), "event": event})
    return result


def _audio_source(cache: Path, track: str) -> tuple[dict[str, Any], list[bytes]] | None:
    manifest_path = cache / f"{track}-manifest.json"
    if not manifest_path.exists():
        return None
    manifest = read_json(manifest_path)
    if manifest.get("track") != track or manifest.get("format") != "pcm_s16le" or manifest.get("sample_rate") != 16000 or manifest.get("channels") != 1:
        raise ValueError(f"Unsupported audio manifest: {cache.name}/{track}")
    chunks = manifest.get("chunks")
    if not isinstance(chunks, list) or len(chunks) > 10000:
        raise ValueError(f"Invalid audio chunk list: {cache.name}/{track}")
    data_parts: list[bytes] = []
    total = 0
    for index, chunk in enumerate(chunks):
        if chunk.get("index") != index or chunk.get("start_sample") != total // 2:
            raise ValueError(f"Non-contiguous source audio: {cache.name}/{track}")
        count = chunk.get("bytes")
        if not isinstance(count, int) or count < 0 or count > 320000 or count % 2:
            raise ValueError(f"Invalid source chunk size: {cache.name}/{track}")
        if count == 0:
            if index != len(chunks) - 1 or chunk.get("sha256") not in (None, ""):
                raise ValueError(f"Invalid empty tail chunk: {cache.name}/{track}")
            continue
        filename = cache / f"{track}-{index:06d}.pcm"
        if filename.is_symlink() or not filename.is_file():
            raise ValueError(f"Missing or unsafe source PCM: {filename.name}")
        data = filename.read_bytes()
        if len(data) != count:
            raise ValueError(f"PCM byte count changed: {cache.name}/{track}")
        expected = chunk.get("sha256")
        if expected and hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"PCM hash mismatch: {cache.name}/{track}")
        data_parts.append(data)
        total += count
    if total != manifest.get("written_bytes"):
        raise ValueError(f"PCM total changed: {cache.name}/{track}")
    return manifest, data_parts


def _write_track(cache: Path, track: str, sources: list[tuple[Path, str]]) -> dict[str, Any]:
    parts: list[tuple[dict[str, Any], bytes]] = []
    for source_dir, source_track in sources:
        audio = _audio_source(source_dir, source_track)
        if audio is None:
            continue
        manifest, chunks = audio
        parts.extend((manifest, chunk) for chunk in chunks)
    if not parts:
        raise ValueError(f"No saved PCM for track {track}")
    merged_manifest = dict(parts[0][0])
    merged_manifest["track"] = track
    merged_manifest["chunks"] = []
    written = 0
    chunk_index = 0
    buffer = bytearray()

    def flush() -> None:
        nonlocal written, chunk_index, buffer
        if not buffer:
            return
        data = bytes(buffer)
        (cache / f"{track}-{chunk_index:06d}.pcm").write_bytes(data)
        merged_manifest["chunks"].append({"index": chunk_index, "start_sample": written // 2,
                                           "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        written += len(data)
        chunk_index += 1
        buffer.clear()

    for _, part in parts:
        position = 0
        while position < len(part):
            amount = min(320000 - len(buffer), len(part) - position)
            buffer.extend(part[position:position + amount])
            position += amount
            if len(buffer) == 320000:
                flush()
    flush()
    if written <= 0:
        raise ValueError(f"Empty merged track {track}")
    merged_manifest.update({"schema": 1, "track": track, "format": "pcm_s16le", "sample_rate": 16000,
                            "channels": 1, "written_bytes": written, "offered_bytes": written,
                            "admitted_pcm_bytes": written, "alignment_padding_bytes": 0,
                            "padding_counters_known": True, "asr_committed_bytes": written,
                            "model_committed_bytes": written, "ended": True, "error": None,
                            "archived": False, "audio_cleaned": False,
                            "contains_voiceprint_embeddings": False})
    merged_manifest["origin_uptime"] = float(parts[0][0].get("origin_uptime") or 0)
    (cache / f"{track}-manifest.json").write_text(json.dumps(merged_manifest, ensure_ascii=False,
                                                             sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    return merged_manifest


def _migrate_coarse(cache: Path, first_id: str, second_id: str, first_session: str, second_session: str,
                    merge_session: str, first_epoch_map: dict[str, str], second_epoch_map: dict[str, str],
                    source_manifests: dict[str, list[dict[str, Any]]], rows: list[dict[str, Any]]) -> dict[str, Any]:
    events = _timeline_events(rows)
    unit_end: dict[str, float] = {}
    capture_origin = read_json(cache / "meeting.json")["capture_origin_uptime"]
    for track, manifests in source_manifests.items():
        end = 0.0
        for manifest in manifests:
            origin = manifest.get("origin_uptime")
            if isinstance(origin, (int, float)):
                end = max(end, float(origin) - float(capture_origin) + manifest["written_bytes"] / 32000)
        unit_end[track] = end
    units = _iter_units(events, unit_end)
    if not units:
        raise ValueError("Merged timeline has no coarse-refinement units")

    source_records: dict[str, dict[str, Any]] = {}
    source_root = cache.parent.parent / "sources"
    second_artifact_path = next((p for p in (source_root / second_id / "automatic-coarse-refinement.json",
                                              source_root / first_id / "automatic-coarse-refinement.json") if p.exists()), None)
    # Locate the one previously completed projection by its source title folder.
    if second_artifact_path is not None:
        source_records[second_id] = read_json(second_artifact_path)

    # Map the existing second-session run IDs to the merged timeline's shifted
    # run IDs. Segment IDs themselves stay stable and unique.
    second_offset = float(next(x["offset_seconds"] for x in read_json(cache.parent.parent / "merge-manifest.json")["sources"]
                               if x["cache_id"] == second_id))
    unit_remap: dict[str, str] = {}
    for row in rows:
        if row.get("merge_source_cache_id") != second_id or row.get("type") != "segment":
            continue
        parent = row.get("segment_id")
        for run in row.get("speaker_runs") or []:
            old = int((float(run["start"]) - second_offset) * 1000 + 0.5)
            new = int(float(run["start"]) * 1000 + 0.5)
            unit_remap[f"{parent}:word:{old}"] = f"{parent}:word:{new}"

    coarse_records: dict[str, dict[str, Any]] = {}
    second_artifact = source_records.get(second_id)
    if second_artifact:
        for record in second_artifact.get("records", []):
            value = dict(record)
            old_unit = value["unit_id"]
            value["unit_id"] = unit_remap.get(old_unit, old_unit)
            key = value.get("speaker_key")
            if isinstance(key, dict):
                value["speaker_key"] = _rewrite(key, old_session=second_session, new_session=merge_session,
                                                offset=0, epoch_map=second_epoch_map, time_fields=False)
            coarse_records[value["unit_id"]] = value
    first_units = [unit for unit in units if unit["event"].get("merge_source_cache_id") == first_id]
    for unit in first_units:
        original = unit["text"]
        coarse_records[unit["unit_id"]] = {"unit_id": unit["unit_id"],
                                            "original_text_sha256": hashlib.sha256(original.encode("utf-8")).hexdigest(),
                                            "text": original}
    expected = {unit["unit_id"] for unit in units}
    if set(coarse_records) != expected:
        raise ValueError(f"Coarse projection coverage mismatch: missing={len(expected-set(coarse_records))}, extra={len(set(coarse_records)-expected)}")

    transcript_hashes = {path.name: sha256(path) for path in sorted(cache.glob("*-transcript.jsonl"))}
    transcript_hashes = dict(sorted(transcript_hashes.items()))
    source_hash = _digest_json(transcript_hashes)
    snapshot_hashes: dict[str, str] = {"meeting.json": sha256(cache / "meeting.json"),
                                       "speaker-reconciliation.json": ""}
    transcript_tracks = {name.removesuffix("-transcript.jsonl") for name in transcript_hashes}
    transcript_tracks.update(track for track in source_manifests
                             if track in ("mic", "remote") or track.startswith("remote-g") or track.startswith("app-"))
    for track in sorted(transcript_tracks):
        manifest_path = cache / f"{track}-manifest.json"
        snapshot_hashes[f"{track}-manifest.json"] = sha256(manifest_path) if manifest_path.exists() else ""
        transcript_path = cache / f"{track}-transcript.jsonl"
        snapshot_hashes[f"{track}-transcript.jsonl"] = transcript_hashes.get(transcript_path.name, "")
    legacy_snapshot = _digest_json(snapshot_hashes)
    names = read_json(cache / "session-names.json")
    stable_names = {"schema": names.get("schema", 0), "session": merge_session,
                    "sentences": names.get("sentences", {}), "speakers": names.get("speakers", []),
                    "assignments": names.get("assignments", []), "aliases": names.get("aliases", []),
                    "runAnchors": names.get("runAnchors", [])}
    for key in ("speakers", "assignments", "aliases", "runAnchors"):
        stable_names[key] = sorted(stable_names[key], key=lambda value: _canonical(value))
    names_hash = _digest_json(stable_names)
    events_hash = _digest_json(events)
    automatic_speaker_hash = ""
    snapshot_hash = _digest_json({"legacy_snapshot_sha256": legacy_snapshot,
                                  "automatic_speaker_sha256": automatic_speaker_hash,
                                  "session_names_sha256": names_hash,
                                  "events_sha256": events_hash})
    artifact = {"schema": 1, "method": "audio_coarse_v1", "model": second_artifact.get("model") if second_artifact else "preserved_identity_projection",
                "cache_id": cache.name, "session": merge_session, "source_sha256": source_hash,
                "snapshot_sha256": snapshot_hash, "records": [coarse_records[unit["unit_id"]] for unit in units],
                "merge_projection": {"unchanged_source_cache_id": first_id,
                                     "preserved_source_cache_id": second_id,
                                     "provider_reexecution": False}}
    (cache / "automatic-coarse-refinement.json").write_text(json.dumps(artifact, ensure_ascii=False,
                                                                         sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    status = {"schema": 1, "session": merge_session, "state": "partial",
              "error": "first_source_had_no_saved_coarse_refinement",
              "updated_at": datetime.now(timezone.utc).isoformat()}
    (cache / "coarse-refinement-status.json").write_text(json.dumps(status, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    preference = {"schema": 1, "session": merge_session, "enabled": True}
    (cache / "coarse-refinement-preference.json").write_text(json.dumps(preference, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    return {"units": len(units), "first_unchanged_units": len(first_units),
            "second_preserved_records": len(second_artifact.get("records", [])) if second_artifact else 0,
            "source_sha256": source_hash, "snapshot_sha256": snapshot_hash}


def _write_app_cache(temp: Path, first_dir: Path, second_dir: Path, first_id: str, second_id: str,
                     first_display: dict[str, Any], second_display: dict[str, Any], first_meeting: dict[str, Any],
                     second_meeting: dict[str, Any], first_session: str, second_session: str,
                     first_anchor: float, second_anchor: float, second_offset: float,
                     first_epoch_map: dict[str, str], second_epoch_map: dict[str, str], rows: list[dict[str, Any]]) -> dict[str, Any]:
    cache_id, merge_session = _merged_ids(first_id, second_id)
    cache = temp / "merged_recording" / cache_id
    cache.mkdir(parents=True)
    track_sources: dict[str, list[tuple[Path, str]]] = {}
    source_manifests: dict[str, list[dict[str, Any]]] = {}
    merged_capture_origin = float(first_meeting["capture_origin_uptime"])
    effective_source_offsets = {first_id: 0.0, second_id: second_offset}
    source_origins = {first_id: float(first_meeting["capture_origin_uptime"]),
                      second_id: float(second_meeting["capture_origin_uptime"])}
    for source_dir in (first_dir, second_dir):
        for path in source_dir.glob("*-manifest.json"):
            track = path.name[:-len("-manifest.json")]
            # Raw mic/reference are preserved byte-for-byte in rollback sources.
            # The app's logical mic playback prefers mic-raw, whose saved first
            # source is shorter than the transcript clock; exporting it would
            # put the second session several seconds ahead of its transcript.
            if track in {"mic-raw", "reference"}:
                continue
            track_sources.setdefault(track, []).append((source_dir, track))
    for track, candidates in sorted(track_sources.items()):
        nonempty = []
        for directory, source_track in candidates:
            audio = _audio_source(directory, source_track)
            if audio and audio[0].get("written_bytes", 0) > 0:
                nonempty.append((directory, source_track))
                source_manifests.setdefault(track, []).append(audio[0])
        if nonempty:
            manifest = _write_track(cache, track, nonempty)
            if len(nonempty) == 1 and nonempty[0][0] == second_dir:
                source_origin = float(manifest.get("origin_uptime") or source_origins[second_id])
                manifest["origin_uptime"] = merged_capture_origin + effective_source_offsets[second_id] + (source_origin - source_origins[second_id])
                (cache / f"{track}-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False,
                                                                          sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")

    first_map: dict[str, str] = {}
    second_map: dict[str, str] = {}
    transformed_rows: list[dict[str, Any]] = []
    max_seq_by_source: dict[str, int] = {}
    first_mic = _audio_source(first_dir, "mic")
    if first_mic is None or not first_mic[0].get("written_bytes"):
        raise ValueError("First source has no committed microphone audio")
    first_sample_count = int(first_mic[0]["written_bytes"]) // 2
    for source_dir, old_session, offset, cache_id_source, epoch_map in (
        (first_dir, first_session, 0.0, first_id, first_map),
        (second_dir, second_session, second_offset, second_id, second_map),
    ):
        source_rows = _load_jsonl(source_dir / "mic-transcript.jsonl")
        for line_index, row in enumerate(source_rows):
            mapped = _rewrite(row, old_session=old_session, new_session=merge_session,
                              offset=offset, epoch_map=epoch_map)
            if mapped.get("session") is None:
                mapped["session"] = merge_session
            source = mapped.get("source_id") or mapped.get("track")
            if isinstance(mapped.get("source_seq"), int) and isinstance(source, str) and cache_id_source == second_id:
                mapped["source_seq"] += max_seq_by_source.get(source, 0)
            elif isinstance(mapped.get("source_seq"), int) and isinstance(source, str):
                max_seq_by_source[source] = max(max_seq_by_source.get(source, 0), mapped["source_seq"])
            if (cache_id_source == second_id and mapped.get("type") == "asr_replay"
                    and mapped.get("track") == "mic" and isinstance(mapped.get("resume_sample"), int)):
                mapped["resume_sample"] += first_sample_count
            event_id = mapped.get("event_id")
            if isinstance(event_id, str):
                mapped["event_id"] = f"{cache_id_source}:{event_id}"
            mapped["merge_source_cache_id"] = cache_id_source
            transformed_rows.append(mapped)
    source_segment_ids = {source: {row.get("segment_id") for row in transformed_rows
                                   if row.get("merge_source_cache_id") == source and row.get("type") == "segment"}
                          for source in (first_id, second_id)}
    collision_ids = source_segment_ids[first_id] & source_segment_ids[second_id]
    if collision_ids:
        raise ValueError("Source segment IDs collide; refusing a merge with ambiguous manual/coarse annotations")
    (cache / "mic-transcript.jsonl").write_text(
        "".join(json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n" for row in transformed_rows),
        encoding="utf-8")
    first_names = read_json(first_dir / "session-names.json")
    second_names = read_json(second_dir / "session-names.json")
    names = _merge_names(first_names, second_names, first_session, second_session, merge_session, second_offset)
    (cache / "session-names.json").write_text(json.dumps(names, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    first_duration = float(source_manifests.get("mic", [{}])[0].get("written_bytes", 0)) / 32000
    second_duration = float(source_manifests.get("mic", [{}])[-1].get("written_bytes", 0)) / 32000
    capture_origin = merged_capture_origin
    metadata = dict(first_meeting)
    metadata.update({"cache_id": cache_id, "session": merge_session, "capture_origin_uptime": capture_origin,
                     "absolute_clock": {"schema": 1, "basis": "capture_clock", "time_zone": "Asia/Shanghai",
                                        "anchors": [{"relative_start": 0.0, "unix_time": first_anchor},
                                                    {"relative_start": second_offset, "unix_time": second_anchor}]},
                     "recording_elapsed_seconds": first_duration + second_duration,
                     "capture_stop_reason": "merged_saved_sessions",
                     "audio_sources": list({(item.get("source_id"), item.get("application_name"), item.get("capture_generation")): item
                                            for meeting in (first_meeting, second_meeting)
                                            for item in meeting.get("audio_sources", [])}.values()),
                     "merge_mapping": {"schema": 1, "source_cache_ids": [first_id, second_id],
                                       "source_sessions": [first_session, second_session],
                                       "effective_audio_gap_seconds": max(0.0, second_anchor - first_anchor - first_duration),
                                       "audio_gap_omitted_from_pcm": True,
                                       "second_timeline_offset_seconds": second_offset,
                                       "speaker_epochs_namespaced": True,
                                       "playback_track": "mic",
                                       "omitted_from_merged_cache": {"mic-raw": "unaligned_with_transcript_clock; original_kept_in_sources",
                                                                      "reference": "non-transcript_track; original_kept_in_sources"},
                                       "source_capture_warnings": [
                                           {"cache_id": cache_id, "track": track,
                                            "ended": manifest.get("ended"),
                                            "asr_committed_bytes": manifest.get("asr_committed_bytes"),
                                            "written_bytes": manifest.get("written_bytes"),
                                            "error": manifest.get("error")}
                                           for cache_id, source_dir in ((first_id, first_dir), (second_id, second_dir))
                                           for track in ("mic", "mic-raw")
                                           if (source_manifest := _audio_source(source_dir, track)) is not None
                                           for manifest in (source_manifest[0],)]}})
    (cache / "meeting.json").write_text(json.dumps(metadata, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    display = {"schema": 2, "cache_id": cache_id, "session": merge_session,
               "title": "点位筛选与投放排期｜11月7日启动可行性验证",
               "provenance": "merged-local-recordings"}
    (cache / "display-info.json").write_text(json.dumps(display, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    controls = {"schema": 1, "session": merge_session, "last_event": "stopped", "reason": "merged_saved_sessions",
                "transcription_complete": True, "capture_gate": "closed"}
    (cache / "recording-control.json").write_text(json.dumps(controls, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    coarse = _migrate_coarse(cache, first_id, second_id, first_session, second_session, merge_session,
                             first_map, second_map, source_manifests, transformed_rows)
    return {"cache_id": cache_id, "session": merge_session, "title": display["title"],
            "audio_tracks": sorted(track for track in track_sources if (cache / f"{track}-manifest.json").exists()),
            "effective_audio_seconds": first_duration + second_duration,
            "coarse_projection": coarse, "folder": f"merged_recording/{cache_id}"}


def prepare_merge(cache_root: Path, stage_root: Path, first_id: str, second_id: str) -> Path:
    first_id, second_id = first_id.upper(), second_id.upper()
    if first_id == second_id:
        raise ValueError("Choose two different meeting IDs")
    if first_id not in EXPECTED or second_id not in EXPECTED:
        raise ValueError("This preparation tool only accepts the two user-selected meetings")
    first_dir, first_display, first_meeting = _validate_source(cache_root, first_id, EXPECTED[first_id])
    second_dir, second_display, second_meeting = _validate_source(cache_root, second_id, EXPECTED[second_id])
    first_session, second_session = first_meeting.get("session"), second_meeting.get("session")
    if not first_session or not second_session or first_session == second_session:
        raise ValueError("Missing or duplicate session identities")
    first_anchor = float(first_meeting["absolute_clock"]["anchors"][0]["unix_time"])
    second_anchor = float(second_meeting["absolute_clock"]["anchors"][0]["unix_time"])
    wall_clock_delta = second_anchor - first_anchor
    if wall_clock_delta <= 0:
        raise ValueError("Selected order must be chronological")
    first_audio = _audio_source(first_dir, "mic")
    if first_audio is None or not first_audio[0].get("written_bytes"):
        raise ValueError("First source has no saved microphone audio")
    second_offset = int(first_audio[0]["written_bytes"]) / 32000.0
    if wall_clock_delta + 0.25 < second_offset:
        raise ValueError("Source recordings overlap in wall time; refusing ambiguous audio ordering")

    _, merge_session = _merged_ids(first_id, second_id)
    stage_root.mkdir(parents=True, exist_ok=True)
    if stage_root.resolve() != DEFAULT_STAGE_ROOT.resolve():
        raise ValueError("Staging destination must be the project merge-staging directory")
    cache_id, _ = _merged_ids(first_id, second_id)
    final_dir = stage_root / cache_id
    if final_dir.exists():
        raise FileExistsError(f"Staging package already exists: {final_dir}")

    source_dirs = ((first_dir, first_id), (second_dir, second_id))
    source_hashes = {cache_id: _walk_files(directory) for directory, cache_id in source_dirs}
    temp = Path(tempfile.mkdtemp(prefix=f".{merge_session}.", dir=stage_root))
    try:
        sources_dir = temp / "sources"
        sources_dir.mkdir()
        for source, cache_id in source_dirs:
            shutil.copytree(source, sources_dir / cache_id, symlinks=False)

        combined = []
        event_ids: set[str] = set()
        for index, (directory, old_session, offset) in enumerate(
                ((first_dir, first_session, 0.0), (second_dir, second_session, second_offset)), 1):
            transcript = directory / "mic-transcript.jsonl"
            if not transcript.is_file():
                raise ValueError(f"Missing mic transcript: {directory.name}")
            epoch_map: dict[str, str] = {}
            rows = _load_jsonl(transcript)
            for row_index, row in enumerate(rows):
                mapped = _rewrite(row, old_session=old_session, new_session=merge_session,
                                  offset=offset, epoch_map=epoch_map)
                original_id = mapped.get("event_id")
                if not isinstance(original_id, str) or not original_id:
                    # Recovery controls such as asr_replay historically have no
                    # event_id/session. Keep them in their source's append order.
                    original_id = str(uuid.uuid5(uuid.UUID(merge_session),
                                                  f"{directory.name}:control:{row_index}:{mapped.get('type')}"))
                    mapped["event_id"] = original_id
                if mapped.get("session") is None:
                    mapped["session"] = merge_session
                if original_id in event_ids:
                    mapped["event_id"] = f"{index}:{original_id}"
                event_ids.add(mapped["event_id"])
                mapped["merge_source_cache_id"] = directory.name
                combined.append(mapped)
        # Preserve append order so replay controls still precede their source's
        # later updates. The consumer can sort visible utterances by start time.
        (temp / "merged-mic-transcript.jsonl").write_text(
            "".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in combined),
            encoding="utf-8")

        first_names = read_json(first_dir / "session-names.json") if (first_dir / "session-names.json").exists() else {"session": first_session}
        second_names = read_json(second_dir / "session-names.json") if (second_dir / "session-names.json").exists() else {"session": second_session}
        (temp / "merged-session-names.json").write_text(
            json.dumps(_merge_names(first_names, second_names, first_session, second_session, merge_session, second_offset),
                       ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

        manifest = {
            "schema": 1,
            "kind": "reversible-meeting-merge-staging",
            "merge_session": merge_session,
            "sources": [
                {"cache_id": first_id, "session": first_session, "title": first_display["title"],
                 "anchor_unix": first_anchor, "offset_seconds": 0.0, "files_sha256": source_hashes[first_id]},
                {"cache_id": second_id, "session": second_session, "title": second_display["title"],
                 "anchor_unix": second_anchor, "offset_seconds": second_offset,
                 "wall_gap_seconds": wall_clock_delta - second_offset, "files_sha256": source_hashes[second_id]},
            ],
            "merged_transcript": "merged-mic-transcript.jsonl",
            "merged_names": "merged-session-names.json",
            "row_count": len(combined),
            "event_ids_unique": len(event_ids) == len(combined),
            "speaker_epochs_namespaced": True,
            "audio_policy": "Original PCM/manifests are preserved byte-for-byte under sources/; verified PCM is concatenated without inserting pause silence.",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        (temp / "merge-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        app_cache = _write_app_cache(temp, first_dir, second_dir, first_id, second_id,
                                     first_display, second_display, first_meeting, second_meeting,
                                     first_session, second_session, first_anchor, second_anchor,
                                     second_offset, {}, {}, combined)
        app_cache["files_sha256"] = _walk_files(temp / app_cache["folder"])
        manifest["app_cache"] = app_cache
        (temp / "merge-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

        # Verify the copied rollback sources exactly match the captured source hashes.
        for _, cache_id in source_dirs:
            actual = _walk_files(sources_dir / cache_id)
            if actual != source_hashes[cache_id]:
                raise IOError(f"Staged source integrity check failed: {cache_id}")
        os.replace(temp, final_dir)
    except BaseException:
        shutil.rmtree(temp, ignore_errors=True)
        raise
    return final_dir


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT)
    parser.add_argument("--stage-root", type=Path, default=DEFAULT_STAGE_ROOT)
    parser.add_argument("--first", help="Chronologically first selected cache UUID")
    parser.add_argument("--second", help="Chronologically second selected cache UUID")
    parser.add_argument("--import-staged", type=Path, help="Review or import one prepared package; dry-run is the default")
    parser.add_argument("--app-info", type=Path, help="Official desktop app Contents/Info.plist that defines AppLockPath")
    parser.add_argument("--apply-import", action="store_true", help="Execute the import after all hash and lock checks")
    parser.add_argument("--rollback-import", metavar="MERGED_UUID", help="Restore both originals from a verified import receipt")
    args = parser.parse_args()
    try:
        if args.rollback_import:
            if not args.app_info or args.import_staged or args.first or args.second or args.apply_import:
                parser.error("--rollback-import requires --app-info and cannot be combined with other operations")
            result = rollback_import(args.cache_root, args.rollback_import, args.app_info)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if args.import_staged:
            if not args.app_info or args.first or args.second:
                parser.error("--import-staged requires --app-info and cannot be combined with --first/--second")
            result = import_staged(args.cache_root, args.import_staged, args.app_info, apply=args.apply_import)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if args.apply_import or args.app_info:
            parser.error("--apply-import and --app-info are valid only with --import-staged")
        if not args.first or not args.second:
            parser.error("provide --first and --second to prepare the selected merge")
        result = prepare_merge(args.cache_root, args.stage_root, args.first, args.second)
    except Exception as exc:
        parser.error(str(exc))
    manifest = read_json(result / "merge-manifest.json")
    print(json.dumps({"staging_directory": str(result), "row_count": manifest["row_count"],
                      "second_offset_seconds": manifest["sources"][1]["offset_seconds"],
                      "app_cache": manifest["app_cache"],
                      "source_cache_ids": [source["cache_id"] for source in manifest["sources"]],
                      "source_copies_verified": True}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
