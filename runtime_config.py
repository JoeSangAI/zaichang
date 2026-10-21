"""Per-user paths shared by the portable recorder and local helper processes."""
from __future__ import annotations

import os
from pathlib import Path


def data_root(environment: dict[str, str] | None = None) -> Path:
    env = os.environ if environment is None else environment
    override = env.get("ZAICHANG_DATA_ROOT", "")
    if override:
        candidate = Path(override).expanduser()
        if candidate.is_absolute() and ".." not in candidate.parts:
            return candidate.resolve()
        if "/" not in override and override not in {".", ".."}:
            return Path.home() / "Library" / "Application Support" / override
    return Path.home() / "Library" / "Application Support" / "ZaichangStandalone"
