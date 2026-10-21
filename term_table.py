"""Read local, user-owned transcription terms from Zaichang's data folder."""
from __future__ import annotations

import json
from pathlib import Path

from runtime_config import data_root


def _rows(path: Path, layer: str) -> dict:
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 1_000_000:
            return dict(path=str(path), layer=layer, rows=[], error="invalid_source")
        raw = json.loads(path.read_text(encoding="utf-8"))
        values = raw.get("terms", []) if isinstance(raw, dict) else []
        if not isinstance(values, list) or len(values) > 1000:
            return dict(path=str(path), layer=layer, rows=[], error="invalid_source")
        clean = []
        for item in values:
            if not isinstance(item, dict):
                continue
            term = item.get("term")
            aliases = item.get("aliases", [])
            misheard = item.get("misheard", [])
            if not isinstance(term, str) or not term.strip() or len(term) > 128:
                continue
            if not isinstance(aliases, list) or not all(isinstance(x, str) and len(x) <= 128 for x in aliases):
                continue
            if not isinstance(misheard, list) or not all(isinstance(x, str) and len(x) <= 128 for x in misheard):
                continue
            clean.append(dict(term=term.strip(), aliases=aliases, misheard=misheard, layer=layer))
        return dict(path=str(path), layer=layer, rows=clean, error=None)
    except (OSError, UnicodeError, json.JSONDecodeError):
        return dict(path=str(path), layer=layer, rows=[], error="invalid_source")


def compile_all() -> list[dict]:
    root = data_root() / "Terms"
    if not root.is_dir() or root.is_symlink():
        return []
    files = sorted(root.glob("*.json"))[:128]
    return [_rows(path, "general") for path in files]


def for_project(project_dir: Path | None) -> list[dict]:
    owners = compile_all()
    if project_dir is None:
        return [row for owner in owners for row in owner["rows"]]
    path = Path(project_dir) / ".zaichang-terms.json"
    owner = _rows(path, "project")
    return owner["rows"] + [row for item in owners for row in item["rows"]]
